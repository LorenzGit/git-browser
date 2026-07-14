import AppKit

// Developer utility: render the app icon to a PNG and exit.
//   GitBrowser --dump-icon /path/to/icon.png
if let flagIndex = CommandLine.arguments.firstIndex(of: "--dump-icon"),
   CommandLine.arguments.count > flagIndex + 1 {
    let outputPath = CommandLine.arguments[flagIndex + 1]
    let icon = AppIcon.make()
    if let tiff = icon.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outputPath))
        print("icon written to \(outputPath)")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
