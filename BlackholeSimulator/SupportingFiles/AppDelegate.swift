import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 applicationDidFinishLaunching")
        // Prevent auto-masking of MTKView; we handle our own sizing.
        NSApplication.shared.mainMenu = nil

        // Create and configure the main window
        let contentRect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered,
                          defer: false)
        let vc = ViewController()
        window.contentViewController = vc
        window.title = "Blackhole Simulator"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("🎯 Window made key and ordered front")
    }

    func applicationWillTerminate(_ notification: Notification) {}
}
