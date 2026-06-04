import Cocoa

print("🚀 App launched")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
print("🎯 AppDelegate set, starting event loop...")

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
