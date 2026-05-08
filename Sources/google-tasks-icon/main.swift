import AppKit
import Foundation
import SwiftUI

@main
@MainActor
struct IconGenerator {
    static func main() throws {
        let outputDirectoryPath = CommandLine.arguments.dropFirst().first ?? ".build/AppIcon.iconset"
        let outputDirectoryURL = URL(fileURLWithPath: outputDirectoryPath)
        try FileManager.default.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)

        for spec in IconSpec.all {
            let image = renderIcon(size: CGSize(width: spec.pixels, height: spec.pixels))
            let outputURL = outputDirectoryURL.appendingPathComponent(spec.fileName)
            try writePNG(image, to: outputURL)
        }
        print("Generated iconset: \(outputDirectoryURL.path)")
    }

    private static func renderIcon(size: CGSize) -> NSImage {
        let view = IconView()
            .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        if let cgImage = renderer.cgImage {
            NSGraphicsContext.current?.cgContext.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }
        image.unlockFocus()
        return image
    }

    private static func writePNG(_ image: NSImage, to url: URL) throws {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw IconError.renderFailed
        }
        try data.write(to: url, options: [.atomic])
    }
}

private struct IconSpec {
    var fileName: String
    var pixels: CGFloat

    static let all = [
        IconSpec(fileName: "icon_16x16.png", pixels: 16),
        IconSpec(fileName: "icon_16x16@2x.png", pixels: 32),
        IconSpec(fileName: "icon_32x32.png", pixels: 32),
        IconSpec(fileName: "icon_32x32@2x.png", pixels: 64),
        IconSpec(fileName: "icon_128x128.png", pixels: 128),
        IconSpec(fileName: "icon_128x128@2x.png", pixels: 256),
        IconSpec(fileName: "icon_256x256.png", pixels: 256),
        IconSpec(fileName: "icon_256x256@2x.png", pixels: 512),
        IconSpec(fileName: "icon_512x512.png", pixels: 512),
        IconSpec(fileName: "icon_512x512@2x.png", pixels: 1024)
    ]
}

private struct IconView: View {
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width, proxy.size.height) / 1024
            let opticalX = 34 * scale
            let opticalY = -30 * scale

            ZStack(alignment: .center) {
                Color.white

                Circle()
                    .stroke(
                        GoogleTasksBlue.color,
                        style: StrokeStyle(lineWidth: 118 * scale, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 620 * scale, height: 620 * scale)
                    .offset(x: (-52 * scale) + opticalX, y: (42 * scale) + opticalY)

                Path { path in
                    path.move(to: CGPoint(x: (348 * scale) + opticalX, y: (520 * scale) + opticalY))
                    path.addLine(to: CGPoint(x: (486 * scale) + opticalX, y: (660 * scale) + opticalY))
                    path.addLine(to: CGPoint(x: (758 * scale) + opticalX, y: (332 * scale) + opticalY))
                }
                .stroke(
                    GoogleTasksBlue.color,
                    style: StrokeStyle(lineWidth: 118 * scale, lineCap: .round, lineJoin: .round)
                )

                Path { path in
                    path.move(to: CGPoint(x: (700 * scale) + opticalX, y: (388 * scale) + opticalY))
                    path.addLine(to: CGPoint(x: (842 * scale) + opticalX, y: (248 * scale) + opticalY))
                }
                .stroke(
                    GoogleTasksBlue.color,
                    style: StrokeStyle(lineWidth: 118 * scale, lineCap: .butt, lineJoin: .round)
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 204 * scale, style: .continuous))
        }
    }
}

private enum GoogleTasksBlue {
    static let color = Color(red: 0.105, green: 0.459, blue: 0.965)
}

private enum IconError: LocalizedError {
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            "Could not render the app icon."
        }
    }
}
