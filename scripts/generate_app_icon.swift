import AppKit

let outputDirectory: String = {
    if CommandLine.arguments.count > 1 {
        return CommandLine.arguments[1]
    }
    return FileManager.default.currentDirectoryPath
}()

let fm = FileManager.default
try fm.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let iconVariants: [(filename: String, pointSize: CGFloat, scale: CGFloat)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2),
]

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawGlyph(in rect: CGRect, symbolName: String, pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
    guard let symbol = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: pointSize, weight: weight)) else {
        return
    }

    let tinted = symbol.copy() as! NSImage
    tinted.lockFocus()
    color.set()
    NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    tinted.draw(in: rect)
}

func drawBackground(in bounds: CGRect) {
    let background = roundedRect(bounds.insetBy(dx: 26, dy: 26), radius: 228)
    NSGraphicsContext.current?.cgContext.saveGState()
    background.addClip()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.30, alpha: 1.0),
        NSColor(calibratedRed: 0.98, green: 0.44, blue: 0.36, alpha: 1.0),
        NSColor(calibratedRed: 0.75, green: 0.26, blue: 0.48, alpha: 1.0),
    ])!
    gradient.draw(in: background, angle: 315)

    let radial = NSGradient(colors: [
        NSColor(calibratedWhite: 1.0, alpha: 0.42),
        NSColor(calibratedWhite: 1.0, alpha: 0.10),
        NSColor(calibratedWhite: 1.0, alpha: 0.0),
    ])!
    radial.draw(
        fromCenter: CGPoint(x: bounds.midX - 120, y: bounds.maxY - 180),
        radius: 40,
        toCenter: CGPoint(x: bounds.midX - 120, y: bounds.maxY - 180),
        radius: 620,
        options: []
    )

    let wavePath = NSBezierPath()
    wavePath.move(to: CGPoint(x: 72, y: 176))
    wavePath.curve(
        to: CGPoint(x: bounds.maxX - 74, y: 236),
        controlPoint1: CGPoint(x: 248, y: 72),
        controlPoint2: CGPoint(x: 740, y: 314)
    )
    wavePath.lineWidth = 44
    NSColor(calibratedWhite: 1.0, alpha: 0.08).setStroke()
    wavePath.stroke()

    NSGraphicsContext.current?.cgContext.restoreGState()

    NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
    background.lineWidth = 2
    background.stroke()
}

func drawWidget(in bounds: CGRect) {
    let cardRect = CGRect(x: 132, y: 618, width: 760, height: 186)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 38
    shadow.shadowOffset = CGSize(width: 0, height: -12)
    shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.28)
    shadow.set()

    let card = roundedRect(cardRect, radius: 96)
    NSColor(calibratedWhite: 0.10, alpha: 0.76).setFill()
    card.fill()

    NSGraphicsContext.current?.cgContext.saveGState()
    card.addClip()
    let cardHighlight = NSGradient(colors: [
        NSColor(calibratedWhite: 1.0, alpha: 0.20),
        NSColor(calibratedWhite: 1.0, alpha: 0.02),
    ])!
    cardHighlight.draw(in: CGRect(x: 132, y: 708, width: 760, height: 96), angle: 90)
    NSGraphicsContext.current?.cgContext.restoreGState()

    let coverRect = CGRect(x: 158, y: 644, width: 134, height: 134)
    let cover = roundedRect(coverRect, radius: 38)
    let coverGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.15, blue: 0.34, alpha: 1.0),
        NSColor(calibratedRed: 0.28, green: 0.43, blue: 0.83, alpha: 1.0),
    ])!
    coverGradient.draw(in: cover, angle: 315)
    NSColor(calibratedWhite: 1.0, alpha: 0.20).setStroke()
    cover.lineWidth = 2
    cover.stroke()

    drawGlyph(
        in: coverRect.insetBy(dx: 24, dy: 24),
        symbolName: "music.note",
        pointSize: 64,
        weight: .bold,
        color: NSColor.white
    )

    let lyricsRect = CGRect(x: 316, y: 650, width: 364, height: 122)
    let lyricsPill = roundedRect(lyricsRect, radius: 46)
    NSColor(calibratedWhite: 1.0, alpha: 0.10).setFill()
    lyricsPill.fill()

    func lyricLine(y: CGFloat, width: CGFloat, alpha: CGFloat) {
        let rect = CGRect(x: 352, y: y, width: width, height: 18)
        let path = roundedRect(rect, radius: 9)
        NSColor(calibratedWhite: 1.0, alpha: alpha).setFill()
        path.fill()
    }

    lyricLine(y: 727, width: 258, alpha: 0.95)
    lyricLine(y: 694, width: 186, alpha: 0.65)

    let progressRect = CGRect(x: 352, y: 670, width: 300, height: 8)
    let progressPath = roundedRect(progressRect, radius: 4)
    NSColor(calibratedWhite: 1.0, alpha: 0.14).setFill()
    progressPath.fill()

    let progressActive = roundedRect(CGRect(x: 352, y: 670, width: 182, height: 8), radius: 4)
    let progressGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.50, alpha: 1.0),
        NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.33, alpha: 1.0),
    ])!
    progressGradient.draw(in: progressActive, angle: 0)

    let controlsOriginX: CGFloat = 722
    let controlsY: CGFloat = 679
    let spacing: CGFloat = 42
    let buttonSize: CGFloat = 42
    let buttonSymbols = ["backward.fill", "pause.fill", "forward.fill"]

    for (index, symbol) in buttonSymbols.enumerated() {
        let x = controlsOriginX + CGFloat(index) * spacing
        let buttonRect = CGRect(x: x, y: controlsY, width: buttonSize, height: buttonSize)
        let button = roundedRect(buttonRect, radius: 21)
        let fillColor: NSColor = index == 1
            ? NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.52, alpha: 1.0)
            : NSColor(calibratedWhite: 1.0, alpha: 0.14)
        fillColor.setFill()
        button.fill()

        let glyphColor: NSColor = index == 1 ? NSColor(calibratedWhite: 0.12, alpha: 1.0) : .white
        drawGlyph(
            in: buttonRect.insetBy(dx: 10, dy: 10),
            symbolName: symbol,
            pointSize: index == 1 ? 17 : 15,
            weight: .black,
            color: glyphColor
        )
    }

    let topBarRect = CGRect(x: 208, y: 840, width: 608, height: 24)
    let topBar = roundedRect(topBarRect, radius: 12)
    NSColor(calibratedWhite: 0.06, alpha: 0.20).setFill()
    topBar.fill()

    let statusDot = roundedRect(CGRect(x: 232, y: 846, width: 12, height: 12), radius: 6)
    NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.52, alpha: 0.95).setFill()
    statusDot.fill()
}

func renderIcon(pixelSize: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)
    context.cgContext.interpolationQuality = .high

    let bounds = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
    NSColor.clear.setFill()
    bounds.fill()

    drawBackground(in: bounds)
    drawWidget(in: bounds)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for variant in iconVariants {
    let pixelSize = Int(variant.pointSize * variant.scale)
    let data = renderIcon(pixelSize: pixelSize)
    let url = URL(fileURLWithPath: outputDirectory).appendingPathComponent(variant.filename)
    try data.write(to: url)
    print("wrote \(url.path)")
}
