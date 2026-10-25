import AppKit

// Build a native SF Symbols icon, keeping the app's visual identity independent.
guard CommandLine.arguments.count == 2 else { fatalError("Pass the Feather resource directory") }
let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let output = resources.appendingPathComponent("Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let gradient = NSGradient(starting: NSColor(red: 0.15, green: 0.09, blue: 0.12, alpha: 1),
                          ending: NSColor(red: 0.04, green: 0.04, blue: 0.07, alpha: 1))!
gradient.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 90)
let config = NSImage.SymbolConfiguration(pointSize: 600, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
let flame = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
flame.draw(in: NSRect(x: 237, y: 180, width: 550, height: 680))
image.unlockFocus()
var rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("EmberSign.png"))
let contents = """
{"images":[{"filename":"EmberSign.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
let iconComposer = resources.appendingPathComponent("AppIcon.icon", isDirectory: true)
if FileManager.default.fileExists(atPath: iconComposer.path) { try FileManager.default.removeItem(at: iconComposer) }
print("Generated EmberSign app icon")
