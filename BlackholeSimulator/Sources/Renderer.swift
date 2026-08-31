import Metal
import MetalKit
import Cocoa
import Foundation
import simd

// MARK: - Main compute-based renderer for the black hole simulation

class BlackholeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary!

    // Pipeline states
    private var rayMarchPS: MTLComputePipelineState!
    private var bloomExtractPS: MTLComputePipelineState!
    private var bloomBlurPS: MTLComputePipelineState!
    private var bloomCombinePS: MTLComputePipelineState!
    private var diskDetailPS: MTLComputePipelineState!
    private var starfieldLensPS: MTLComputePipelineState!

    // Intermediate textures (RGBA16Float = 8 bytes per pixel)
    private var sceneTex: MTLTexture?
    private var bloomTex: MTLTexture?
    private var blurredBloomTex: MTLTexture?
    private var drawableTex: MTLTexture?
    private var compositeTex: MTLTexture?

    // Blur weight/offset buffers
    private var blurWeightsBuffer: MTLBuffer?
    private var blurOffsetsBuffer: MTLBuffer?

    // State
    private var simState: SimState = SimState()
    private var paramsBuffer: MTLBuffer?
    private var camera: Camera = Camera()

    // FPS tracking
    private(set) var currentFPS: Double = 0
    private var frameCount: Int = 0
    private var lastFPSUpdate: CFAbsoluteTime = 0

    // Metal drawable texture from the MTKView
    private var drawableTexture: MTLTexture?
    private var drawableSize: CGSize = .zero
    private var threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)

    private var mtkView: MTKView!
    private var isInitialized = false
    private weak var window: NSWindow?

    // Texture helper
    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    // Locate Shaders.metallib. `Bundle.url(forResource:)` does not search
    // subfolders and the library ships in Resources/Shaders/, so resolve it
    // explicitly — independent of the current working directory.
    private static func shadersLibraryURL() -> URL {
        let fm = FileManager.default
        if let resPath = Bundle.main.resourcePath {
            let base = URL(fileURLWithPath: resPath)
            for candidate in [
                base.appendingPathComponent("Shaders.metallib"),
                base.appendingPathComponent("Shaders/Shaders.metallib"),
            ] {
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        let devPath = "build/BlackholeSimulator.app/Contents/Resources/Shaders/Shaders.metallib"
        if fm.fileExists(atPath: devPath) {
            return URL(fileURLWithPath: devPath)
        }
        fatalError("Shaders.metallib not found. Rebuild with ./direct_build.sh "
            + "(expected in the app bundle's Resources or at \(devPath) relative to the working directory).")
    }

    // === Init ===
    init(mtkView: MTKView) {
        self.mtkView = mtkView
        self.device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!

        // Load the precompiled shader library from the app bundle
        let libraryURL = Self.shadersLibraryURL()
        do {
            self.library = try device.makeLibrary(URL: libraryURL)
        } catch {
            fatalError("Failed to load Metal library at \(libraryURL.path): \(error)")
        }

        super.init()
        self.mtkView.delegate = self
        self.mtkView.enableSetNeedsDisplay = false   // ← auto-draw via draw(in:) — was TRUE (bug)
        self.mtkView.isPaused = false                 // ← ensure frame loop runs
        self.mtkView.preferredFramesPerSecond = 60    // ← V-sync at 60 fps
        self.mtkView.colorPixelFormat = .rgba16Float
        self.mtkView.framebufferOnly = false
        self.mtkView.depthStencilPixelFormat = .depth32Float
        self.mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Start FPS counter
        self.lastFPSUpdate = CFAbsoluteTimeGetCurrent()
        self.frameCount = 0
    }

    // Build a compute pipeline with an actionable error if the function is
    // missing (e.g. a stale Shaders.metallib after a shader change)
    private func makePipelineState(named name: String) -> MTLComputePipelineState {
        guard let fn = library.makeFunction(name: name) else {
            fatalError("Shader function '\(name)' not found in Shaders.metallib — rebuild with ./direct_build.sh")
        }
        guard let ps = try? device.makeComputePipelineState(function: fn) else {
            fatalError("Failed to create compute pipeline state for '\(name)'")
        }
        return ps
    }

    // === Metal init (call from viewDidLoad or similar) ===
    func initMetal(window: NSWindow?) {
        self.window = window

        self.camera.updateOrientation()

        // Create Params buffer (still uses buffer for uniform params)
        let vm = self.camera.viewMatrix()
        let camParams = CameraViewMatrix(
            pos: vm.camPos, right: vm.right, up: vm.up, fwd: vm.forward,
            imageWidth: Int32(mtkView.drawableSize.width),
            imageHeight: Int32(mtkView.drawableSize.height))
        var params = simState.toParams(camParams)
        self.paramsBuffer = device.makeBuffer(bytes: &params,
                                               length: MemoryLayout<SimParams>.stride,
                                               options: .storageModeShared)!

        // Create blur weight buffer
        let blurWeights: [Float] = [
            0.0010, 0.0027, 0.0065, 0.0130, 0.0230, 0.0352,
            0.0459, 0.0459, 0.0352, 0.0230, 0.0130, 0.0065, 0.0027
        ]
        let blurOffsets: [Int] = [-6,-5,-4,-3,-2,-1,0,1,2,3,4,5,6]
        self.blurWeightsBuffer = device.makeBuffer(bytes: blurWeights,
                                                    length: MemoryLayout<Float>.stride * 13,
                                                    options: .storageModeShared)!
        self.blurOffsetsBuffer = device.makeBuffer(bytes: blurOffsets,
                                                    length: MemoryLayout<Int>.stride * 13,
                                                    options: .storageModeShared)!

        // Create pipeline states
        self.rayMarchPS = makePipelineState(named: "ray_march")
        self.bloomExtractPS = makePipelineState(named: "bloom_extract")
        self.bloomBlurPS = makePipelineState(named: "gaussian_blur")
        self.bloomCombinePS = makePipelineState(named: "bloom_combine")
        self.diskDetailPS = makePipelineState(named: "disk_detail")
        self.starfieldLensPS = makePipelineState(named: "starfield_lens")

        // Create blit render pipeline (fullscreen quad → passthrough fragment)
        // MTLBlitCommandEncoder is used instead of render pipeline blit
        // (pipeline code removed - see draw(in:) for blit encoder implementation)
        // self.blitPipelineState = try! device.makeRenderPipelineState(descriptor: blitDesc)

        // Allocate frame textures (use rgba16Float for compute, convert to bgra8Unorm for display)
        let w = Int(mtkView.drawableSize.width)
        let h = Int(mtkView.drawableSize.height)
        let sceneDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        sceneDesc.usage = [.shaderRead, .shaderWrite]
        sceneDesc.storageMode = .shared
        self.sceneTex = device.makeTexture(descriptor: sceneDesc)

        let bloomDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        bloomDesc.usage = [.shaderRead, .shaderWrite]
        bloomDesc.storageMode = .shared
        self.bloomTex = device.makeTexture(descriptor: bloomDesc)
        self.blurredBloomTex = device.makeTexture(descriptor: bloomDesc)
        
        let compositeDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w,
            height: h,
            mipmapped: false
        )
        compositeDesc.usage = [.shaderRead, .shaderWrite]
        compositeDesc.storageMode = .shared
        self.compositeTex = device.makeTexture(descriptor: compositeDesc)

        isInitialized = true
    }

    // === Update params per frame ===
    private func updateParams() {
        self.camera.updateOrientation()
        let vm = self.camera.viewMatrix()
        let camParams = CameraViewMatrix(
            pos: vm.camPos, right: vm.right, up: vm.up, fwd: vm.forward,
            imageWidth: Int32(mtkView.drawableSize.width),
            imageHeight: Int32(mtkView.drawableSize.height))
        var params = self.simState.toParams(camParams)
        guard let pb = self.paramsBuffer else { return }
        memcpy(pb.contents(), &params, MemoryLayout<SimParams>.stride)
    }

    // === MTKViewDelegate: draw(in:) ===
    func draw(in view: MTKView) {
        print("🖼 draw called")
        // FPS tracking
        self.frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - self.lastFPSUpdate >= 1.0 {
            self.currentFPS = Double(self.frameCount) / (now - self.lastFPSUpdate)
            self.frameCount = 0
            self.lastFPSUpdate = now
            if let w = self.window {
                w.title = "Blackhole Sim \(Int(self.currentFPS)) FPS"
            }
        }

        // Update camera position
        self.camera.updateOrientation()
        self.updateParams()

        guard isInitialized else { print("❌ not initialized"); return }
        guard let drawable = view.currentDrawable else { print("❌ no drawable"); return }
        print("✅ got drawable, size: \(view.drawableSize)")
        
        guard let commandBuffer = self.commandQueue.makeCommandBuffer() else { print("❌ no commandBuffer"); return }
        print("✅ got commandBuffer")
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { print("❌ no encoder"); return }
        print("✅ got encoder")

        let threadGroupCount = MTLSize(width: Int(ceil(view.drawableSize.width / 16.0)),
                                        height: Int(ceil(view.drawableSize.height / 16.0)),
                                        depth: 1)
        print("🧵 drawableSize: \(view.drawableSize)")
        print("🧵 threadGroupCount: \(threadGroupCount.width) x \(threadGroupCount.height) x \(threadGroupCount.depth)")

        self.drawableTexture = drawable.texture
        self.drawableSize = view.drawableSize

        // 1. Ray marching pass (main scene)
        // Sets: buffer(0)=params, texture(1)=sceneTex (write), texture(2)=drawableTex (write)
        encoder.setComputePipelineState(self.rayMarchPS)
        encoder.setBuffer(self.paramsBuffer, offset: 0, index: 0)
        encoder.setTexture(self.sceneTex, index: 1)
        encoder.setTexture(self.compositeTex, index: 2)
        encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)

        // 2. Bloom extract pass
        // Reads: sceneTex (texture 1) → Writes: bloomTex (texture 2)
        encoder.setComputePipelineState(self.bloomExtractPS)
        encoder.setBuffer(self.paramsBuffer, offset: 0, index: 0)
        encoder.setTexture(self.sceneTex, index: 1)
        encoder.setTexture(self.bloomTex, index: 2)
        encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)

        // 3. Gaussian blur horizontal pass
        // Reads: bloomTex (texture 1) → Writes: blurredBloomTex (texture 2)
        encoder.setComputePipelineState(self.bloomBlurPS)
        encoder.setBuffer(self.paramsBuffer, offset: 0, index: 0)
        encoder.setTexture(self.bloomTex, index: 1)
        encoder.setTexture(self.blurredBloomTex, index: 2)
        encoder.setBuffer(self.blurWeightsBuffer, offset: 0, index: 3)
        encoder.setBuffer(self.blurOffsetsBuffer, offset: 0, index: 4)
        encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)

        // 4. Gaussian blur vertical pass (swap source and dest)
        // Reads: blurredBloomTex (texture 1) → Writes: bloomTex (texture 2)
        encoder.setComputePipelineState(self.bloomBlurPS)
        encoder.setBuffer(self.paramsBuffer, offset: 0, index: 0)
        encoder.setTexture(self.blurredBloomTex, index: 1)
        encoder.setTexture(self.bloomTex, index: 2)
        encoder.setBuffer(self.blurWeightsBuffer, offset: 0, index: 3)
        encoder.setBuffer(self.blurOffsetsBuffer, offset: 0, index: 4)
        encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)

        // 5. Bloom combine pass
        // Reads: sceneTex (texture 1), bloomTex (texture 2) → Writes: drawableTex (texture 3), compositeTex (texture 4)
        encoder.setComputePipelineState(self.bloomCombinePS)
        encoder.setBuffer(self.paramsBuffer, offset: 0, index: 0)
        encoder.setTexture(self.sceneTex, index: 1)
        encoder.setTexture(self.bloomTex, index: 2)
        encoder.setTexture(self.compositeTex, index: 3)
        encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)

        // 6. Disk detail pass (reads sceneTex, writes compositeTex)
        encoder.setComputePipelineState(self.diskDetailPS)
        encoder.setBuffer(self.paramsBuffer, offset: 0, index: 0)
        encoder.setTexture(self.sceneTex, index: 1)
        encoder.setTexture(self.compositeTex, index: 2)
        encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)

        // 7. Starfield lensing pass (reads compositeTex, writes back to compositeTex)
        encoder.setComputePipelineState(self.starfieldLensPS)
        encoder.setBuffer(self.paramsBuffer, offset: 0, index: 0)
        encoder.setTexture(self.compositeTex, index: 1)
        encoder.setTexture(self.compositeTex, index: 2)
        encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)

        encoder.endEncoding()
        print("✅ encoder ended")
        
        // Final: blit from compositeTex to drawable using MTLBlitCommandEncoder
        // This is more reliable than render pass blit for compute-to-display
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            print("❌ no blit encoder")
            return
        }
        
        // Copy from compositeTex (compute output) to drawable texture (display)
        let sourceSize = MTLSize(width: Int(view.drawableSize.width),
                                 height: Int(view.drawableSize.height),
                                 depth: 1)
        blitEncoder.copy(from: self.compositeTex!,
                         sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: sourceSize,
                         to: drawable.texture,
                         destinationSlice: 0, destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blitEncoder.endEncoding()
        print("✅blit encoder done")
        
        commandBuffer.present(drawable)
        print("✅ present called")
        commandBuffer.commit()
        print("✅ commit called")
    }

    // === MTKViewDelegate: resize ===
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        self.drawableSize = size
        self.isInitialized = false
        self.initMetal(window: self.window)
        self.isInitialized = true
    }

    // === Handle events ===
    func handleEvent(_ event: NSEvent) {
        switch event.type {
        case .rightMouseDown, .leftMouseDragged:
            let loc = event.locationInWindow
            let dx = Float(loc.x - (orbitStartLoc?.x ?? 0))
            let dy = Float(loc.y - (orbitStartLoc?.y ?? 0))
            orbitStartLoc = loc
            camera.orbit(dx: dx, dy: dy)
        case .scrollWheel:
            camera.zoom(Float(event.scrollingDeltaY))
        case .keyDown:
            let keyCode = event.keyCode
            switch keyCode {
            case 50: simState.adjustSteps(64)   // +
            case 45: simState.adjustSteps(-64)  // -
            case 40: simState.toggleBloom()      // B
            case 2:  simState.toggleDisk()       // D
            case 5:  simState.nextMass()          // M
            default: break
            }
        default:
            break
        }
    }

    private var orbitStartLoc: NSPoint?
}

// MARK: - Camera view matrix helper
struct CameraViewMatrix {
    let pos: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let fwd: SIMD3<Float>
    let imageWidth: Int32
    let imageHeight: Int32
}
