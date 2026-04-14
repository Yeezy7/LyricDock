import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let playerMonitor = PlayerMonitor()
    let appearanceSettings = AppearanceSettings()

    private let launchAtLoginController = LaunchAtLoginController()
    private var statusItem: NSStatusItem?
    private var statusHostingView: StatusBarHostingView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createStatusItemIfNeeded()
        playerMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        playerMonitor.stop()
    }

    @objc
    private func refreshLyrics(_ sender: Any?) {
        playerMonitor.manualRefresh()
    }

    @objc
    private func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    @objc
    private func handleMenuWidthSlider(_ sender: NSSlider) {
        let width = sender.doubleValue.rounded()
        appearanceSettings.updateMenuBarWidth(width)
        updateStatusItemWidth(width)
        if let sliderView = sender.superview as? MenuWidthControlView {
            sliderView.updateValueLabel(width: width)
        }
    }

    @objc
    private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            let newValue = !launchAtLoginController.isEnabled
            try launchAtLoginController.setEnabled(newValue)
            sender.state = launchAtLoginController.isEnabled ? .on : .off
        } catch {
            NSSound.beep()
        }
    }

    private func createStatusItemIfNeeded() {
        guard statusItem == nil else {
            return
        }

        let width = appearanceSettings.preferences.menuBarWidth
        let item = NSStatusBar.system.statusItem(withLength: width)

        guard let button = item.button else {
            statusItem = item
            return
        }

        button.image = nil
        button.title = ""

        let rootView = AnyView(
            MenuBarTransportBarView()
            .environmentObject(playerMonitor)
            .environmentObject(appearanceSettings)
        )

        let hostingView = StatusBarHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.setFrameSize(NSSize(width: width, height: NSStatusBar.system.thickness))
        hostingView.onRightClick = { [weak self] event, view in
            self?.showContextMenu(with: event, from: view)
        }

        button.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: button.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        statusHostingView = hostingView
        statusItem = item
    }

    private func updateStatusItemWidth(_ width: Double) {
        statusItem?.length = width
        statusHostingView?.setFrameSize(NSSize(width: width, height: NSStatusBar.system.thickness))
    }

    private func showContextMenu(with event: NSEvent, from view: NSView) {
        let menu = makeContextMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let widthItem = NSMenuItem()
        widthItem.view = MenuWidthControlView(
            width: appearanceSettings.preferences.menuBarWidth,
            target: self,
            action: #selector(handleMenuWidthSlider(_:))
        )
        menu.addItem(widthItem)
        menu.addItem(.separator())

        let launchItem = NSMenuItem(
            title: "开机自启",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = launchAtLoginController.isEnabled ? .on : .off
        menu.addItem(launchItem)

        let refreshItem = NSMenuItem(
            title: "立即刷新歌词",
            action: #selector(refreshLyrics(_:)),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 LyricDock",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }
}

private final class StatusBarHostingView: NSHostingView<AnyView> {
    var onRightClick: ((NSEvent, NSView) -> Void)?

    override func rightMouseUp(with event: NSEvent) {
        onRightClick?(event, self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?(event, self)
            return
        }

        super.mouseDown(with: event)
    }
}

private final class MenuWidthControlView: NSView {
    private let valueLabel: NSTextField

    init(width: Double, target: AnyObject, action: Selector) {
        valueLabel = NSTextField(labelWithString: "\(Int(width.rounded())) pt")
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 54))

        let titleLabel = NSTextField(labelWithString: "菜单栏宽度")
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 14, y: 31, width: 120, height: 16)
        addSubview(titleLabel)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 146, y: 31, width: 72, height: 16)
        addSubview(valueLabel)

        let slider = NSSlider(value: width, minValue: 280, maxValue: 560, target: target, action: action)
        slider.isContinuous = true
        slider.frame = NSRect(x: 12, y: 10, width: 208, height: 20)
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateValueLabel(width: Double) {
        valueLabel.stringValue = "\(Int(width.rounded())) pt"
    }
}

private struct LaunchAtLoginController {
    var isEnabled: Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }

        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        default:
            return false
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            return
        }

        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
