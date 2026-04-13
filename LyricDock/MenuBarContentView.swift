import AppKit
import SwiftUI

@MainActor
final class MenuBarArtworkModel: ObservableObject {
    @Published private(set) var image: NSImage?

    private let lookupService = ArtworkLookupService()
    private var loadTask: Task<Void, Never>?
    private var cache: [String: NSImage] = [:]
    private var currentIdentity: String?

    deinit {
        loadTask?.cancel()
    }

    func update(track: TrackMetadata?) {
        let identity = track?.normalizedIdentity
        guard identity != currentIdentity || image == nil else {
            return
        }

        currentIdentity = identity
        loadTask?.cancel()

        guard let identity else {
            image = nil
            return
        }

        if let cached = cache[identity] {
            image = cached
            return
        }

        image = nil
        loadTask = Task { [weak self] in
            guard let self else {
                return
            }

            let sourceArtworkData = try? await AppleMusicScriptBridge.fetchCurrentArtworkData()
            let artworkData: Data?
            if let sourceArtworkData, !sourceArtworkData.isEmpty {
                artworkData = sourceArtworkData
            } else if let track {
                artworkData = await lookupService.artworkData(for: track)
            } else {
                artworkData = nil
            }
            guard
                let artworkData,
                let artwork = NSImage(data: artworkData)
            else {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard self.currentIdentity == identity else {
                    return
                }

                self.cache[identity] = artwork
                self.image = artwork
            }
        }
    }
}

private extension String {
    func width(using font: NSFont) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((self as NSString).size(withAttributes: attributes).width)
    }
}

private struct ScrollingStatusText: View {
    let text: String
    let width: CGFloat
    let date: Date

    private let font = NSFont.systemFont(ofSize: 12.5, weight: .bold)
    private let gap: CGFloat = 28
    private let speed: CGFloat = 32

    var body: some View {
        let measuredWidth = text.width(using: font)

        Group {
            if measuredWidth <= width {
                Text(text)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            } else {
                let travel = measuredWidth + gap
                let offset = scrollingOffset(travel: travel)

                HStack(spacing: gap) {
                    textView
                    textView
                }
                .frame(width: width, alignment: .leading)
                .offset(x: offset)
                .clipped()
            }
        }
        .foregroundStyle(Color.primary.opacity(0.96))
        .padding(.vertical, 1)
        .padding(.horizontal, 2)
    }

    private var textView: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .bold, design: .rounded))
            .fixedSize(horizontal: true, vertical: false)
    }

    private func scrollingOffset(travel: CGFloat) -> CGFloat {
        let cycleDuration = travel / speed
        let initialPause: TimeInterval = 1.1
        let timeInCycle = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration + initialPause)

        if timeInCycle < initialPause {
            return 0
        }

        let progress = CGFloat((timeInCycle - initialPause) / cycleDuration)
        return -travel * progress
    }
}

struct MenuBarTransportBarView: View {
    private static let trackTransitionDisplayDuration: TimeInterval = 2.2

    @EnvironmentObject private var playerMonitor: PlayerMonitor
    @EnvironmentObject private var appearanceSettings: AppearanceSettings
    @StateObject private var artworkModel = MenuBarArtworkModel()
    @State private var lastTrackIdentity: String?
    @State private var lastTrackChangeDate = Date.distantPast

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let snapshot = playerMonitor.snapshot
            let lyricWindow = snapshot.lyricWindow(at: context.date)
            let track = snapshot.track
            let displayText = menuBarText(snapshot: snapshot, lyricWindow: lyricWindow, date: context.date)
            let preferences = appearanceSettings.preferences
            let textWidth = max(150, preferences.menuBarWidth - 136)

            HStack(spacing: 7) {
                Button(action: playerMonitor.openCurrentPlayerApp) {
                    artworkView
                }
                .buttonStyle(.plain)
                .help("打开当前播放器")

                Button(action: playerMonitor.openCurrentPlayerApp) {
                    ScrollingStatusText(
                        text: displayText,
                        width: textWidth,
                        date: context.date
                    )
                }
                .buttonStyle(.plain)
                .help("打开当前播放器")

                HStack(spacing: 4) {
                    transportButton(systemName: "backward.fill", action: playerMonitor.previousTrack)
                    transportButton(
                        systemName: snapshot.state == .playing ? "pause.fill" : "play.fill",
                        emphasized: true,
                        action: playerMonitor.togglePlayPause
                    )
                    transportButton(systemName: "forward.fill", action: playerMonitor.nextTrack)
                }
            }
            .padding(.horizontal, 4)
            .frame(height: NSStatusBar.system.thickness)
            .contentShape(Rectangle())
            .onAppear {
                if lastTrackIdentity == nil {
                    lastTrackIdentity = track?.normalizedIdentity
                    lastTrackChangeDate = context.date
                }
                artworkModel.update(track: track)
            }
            .onChange(of: track?.normalizedIdentity) { _, _ in
                lastTrackIdentity = track?.normalizedIdentity
                lastTrackChangeDate = Date()
                artworkModel.update(track: track)
            }
            .onChange(of: snapshot.updatedAt) { _, _ in
                artworkModel.update(track: track)
            }
            .help(trackTooltip(snapshot: snapshot, lyricWindow: lyricWindow))
        }
    }

    private var artworkView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.09))

            if let image = artworkModel.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let icon = currentPlayerAppIcon() {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 10.5, weight: .bold))
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.6)
        )
    }

    private func transportButton(
        systemName: String,
        emphasized: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        StatusTransportButton(systemName: systemName, emphasized: emphasized, action: action)
    }

    private func menuBarText(snapshot: PlaybackSnapshot, lyricWindow: LyricWindow, date: Date) -> String {
        guard let track = snapshot.track else {
            return "等待播放"
        }

        let isTrackTransition = date.timeIntervalSince(lastTrackChangeDate) < Self.trackTransitionDisplayDuration
        if isTrackTransition {
            return track.displayText
        }

        if snapshot.lyricSource == "正在查找歌词…" {
            return track.displayText
        }

        if appearanceSettings.preferences.menuBarPreferLyrics,
           snapshot.state.isPlaying,
           lyricWindow.current != "等待播放器开始播放",
           lyricWindow.current != track.title {
            return lyricWindow.current
        }

        return track.displayText
    }

    private func trackTooltip(snapshot: PlaybackSnapshot, lyricWindow: LyricWindow) -> String {
        guard let track = snapshot.track else {
            return "等待播放"
        }

        return "\(track.title)\n\(track.subtitle)\n\(lyricWindow.current)"
    }

    private func currentPlayerAppIcon() -> NSImage? {
        guard
            let bundleIdentifier = playerMonitor.snapshot.sourceBundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct StatusTransportButton: View {
    let systemName: String
    let emphasized: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: emphasized ? 10.5 : 9.8, weight: .black))
                .frame(width: emphasized ? 22 : 20, height: emphasized ? 22 : 20)
        }
        .buttonStyle(StatusTransportButtonStyle(emphasized: emphasized, isHovering: isHovering))
        .onHover { isHovering = $0 }
        .help(label)
    }

    private var label: String {
        switch systemName {
        case "backward.fill":
            return "上一首"
        case "forward.fill":
            return "下一首"
        case "pause.fill":
            return "暂停"
        default:
            return "播放"
        }
    }
}

private struct StatusTransportButtonStyle: ButtonStyle {
    let emphasized: Bool
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed

        return configuration.label
            .foregroundStyle(emphasized ? Color.black.opacity(pressed ? 0.65 : 0.85) : Color.primary.opacity(0.92))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor(pressed: pressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(borderColor(pressed: pressed), lineWidth: 1)
            )
            .scaleEffect(pressed ? 0.94 : (isHovering ? 1.03 : 1.0))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isHovering)
    }

    private func backgroundColor(pressed: Bool) -> Color {
        if emphasized {
            return Color(red: 0.98, green: 0.84, blue: 0.54).opacity(pressed ? 0.88 : 1.0)
        }

        return Color.primary.opacity(isHovering ? 0.16 : 0.08)
    }

    private func borderColor(pressed: Bool) -> Color {
        if emphasized {
            return .white.opacity(pressed ? 0.12 : 0.2)
        }

        return .white.opacity(isHovering ? 0.18 : 0.08)
    }
}

#if DEBUG
#Preview {
    MenuBarTransportBarView()
        .environmentObject(PlayerMonitor())
        .environmentObject(AppearanceSettings())
}
#endif
