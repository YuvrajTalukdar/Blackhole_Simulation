import Cocoa
import Metal
import MetalKit

class ViewController: NSViewController {
    private var renderer: BlackholeRenderer?
    private var metalView: MTKView!
    private var fpsLayer: CATextLayer!

    override func loadView() {
        self.view = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 1280, height: 800)))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        print("🎮 ViewController loaded")

        guard let device = MTLCreateSystemDefaultDevice() else {
            NSAlert(error: NSError(
                domain: "BlackholeSimulator",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Metal is not supported on this device."])
            ).runModal()
            NSApplication.shared.terminate(nil)
            return
        }

        metalView = MTKView(frame: view.bounds, device: device)
        metalView.autoresizingMask = [.width, .height]
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.device = device

        // Create FPS overlay layer
        fpsLayer = CATextLayer()
        fpsLayer.frame = CGRect(x: 10, y: 10, width: 150, height: 30)
        fpsLayer.string = "FPS: 60"
        fpsLayer.fontSize = 18
        fpsLayer.foregroundColor = NSColor.white.cgColor
        view.layer?.addSublayer(fpsLayer)

        // Create renderer
        renderer = BlackholeRenderer(mtkView: metalView)
        renderer?.initMetal(window: self.view.window)
        metalView.delegate = renderer as! (any MTKViewDelegate)

        // Debug: verify delegate and draw setup
        print("📐 mtkView frame: \(metalView.frame)")
        print("📐 mtkView device: \(String(describing: metalView.device))")
        print("📐 mtkView delegate: \(String(describing: metalView.delegate))")
        print("📐 mtkView enableSetNeedsDisplay: \(metalView.enableSetNeedsDisplay)")
        print("📐 mtkView isPaused: \(metalView.isPaused)")
        print("📐 mtkView preferredFramesPerSecond: \(metalView.preferredFramesPerSecond)")

        view.addSubview(metalView)
    }

    private var fpsTimer: Timer?

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeKey()
        view.window?.title = "Blackhole Simulator"
        view.window?.styleMask.insert(.titled)
        view.window?.styleMask.insert(.closable)
        view.window?.styleMask.insert(.resizable)
        view.window?.styleMask.insert(.miniaturizable)

        // Update FPS label periodically
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.fpsLayer.string = "FPS: \(Int(self.renderer?.currentFPS ?? 0))"
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        renderer?.handleEvent(event)
    }

    override func mouseDragged(with event: NSEvent) {
        renderer?.handleEvent(event)
    }

    override func scrollWheel(with event: NSEvent) {
        renderer?.handleEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        renderer?.handleEvent(event)
    }
}
