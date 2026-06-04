import Metal
import MetalKit
import Cocoa
import Foundation
import simd

// MARK: - Main compute-based renderer for the black hole simulation

class BlackholeRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

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

    // === Init ===
    init(mtkView: MTKView) {
        self.mtkView = mtkView
        self.device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!

        // Load shaders from Metal default library (auto-compiles .metal files in Resources)
        let libraryURL = Bundle.main.url(forResource: "Shaders", withExtension: "metallib")
                      ?? URL(fileURLWithPath: "build/BlackholeSimulator.app/Contents/Resources/Shaders/Shaders.metallib")
        self.library = try! device.makeLibrary(URL: libraryURL)
        self.computeEncoderType = MTLComputeCommandEncoder.self

        super.init()
        self.mtkView.delegate = self
        self.mtkView.enableSetNeedsDisplay = true
        self.mtkView.colorPixelFormat = .rgba16Float
        self.mtkView.depthStencilPixelFormat = .depth32Float
        self.mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Start FPS counter
        self.lastFPSUpdate = CFAbsoluteTimeGetCurrent()
        self.frameCount = 0
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
        self.rayMarchPS = try! device.makeComputePipelineState(function: library.makeFunction(name: "ray_march")!)
        self.bloomExtractPS = try! device.makeComputePipelineState(function: library.makeFunction(name: "bloom_extract")!)
        self.bloomBlurPS = try! device.makeComputePipelineState(function: library.makeFunction(name: "gaussian_blur")!)
        self.bloomCombinePS = try! device.makeComputePipelineState(function: library.makeFunction(name: "bloom_combine")!)
        self.diskDetailPS = try! device.makeComputePipelineState(function: library.makeFunction(name: "disk_detail")!)
        self.starfieldLensPS = try! device.makeComputePipelineState(function: library.makeFunction(name: "starfield_lens")!)

        // Allocate frame textures
        let w = Int(mtkView.drawableSize.width)
        let h = Int(mtkView.drawableSize.height)
        self.sceneTex = makeTexture(width: w, height: h)
        self.bloomTex = makeTexture(width: w, height: h)
        self.blurredBloomTex = makeTexture(width: w, height: h)
        self.compositeTex = makeTexture(width: w, height: h)

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

        guard isInitialized else { return }
        guard let drawable = view.currentDrawable else { return }

        // Update camera position
        self.camera.updateOrientation()
        self.updateParams()

        self.drawableTexture = drawable.texture
        self.drawableSize = view.drawableSize

        let threadGroupCount = MTLSize(width: Int(ceil(view.drawableSize.width / 16.0)),
                                        height: Int(ceil(view.drawableSize.height / 16.0)),
                                        depth: 1)

        // DIAGNOSTIC: print params
        var simP = self.simState.params
        print("📊 rs=\(simP.rs) disk_r_in=\(simP.disk_r_in) disk_r_out=\(simP.disk_r_out) cam_pos=\(simP.cam_pos) exposure=\(simP.exposure) nsteps=\(simP.nsteps) diskVisible=\(simP.disk_visible) bloomOn=\(simP.bloom_on) imgW=\(simP.image_width) imgH=\(simP.image_height)")

        // === COMPUTE PASS ===

        guard let cmdBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else { return }
        let enc = cmdBuffer.makeComputeCommandEncoder()!

        // === DIAGNOSTIC: bypass ALL post-processing - only run ray_march ===
        // Pass 1: Ray marching (unchanged)
        encoder.setComputePipelineState(self.rayMarchPS)
        encoder.setBuffer(self.paramsBuffer, offset: 0, index: 0)
        encoder.setTexture(self.sceneTex, index: 1)
        encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        // === RENDER PASS: blit sceneTex directly to drawable (no post-processing) ===
        // Compile blit shaders at runtime since they can't live in .metallib
        let blitSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        vertex float4 blit_vert(uint vid [[vertex_id]]) {
            float2 pos[4] = {
                float2(-1, -1), float2(1, -1),
                float2(-1, 1), float2(1, 1)
            };
            return float4(pos[vid], 0.0, 1.0);
        }
        
        fragment float4 blit_frag(float4 pos [[position]],
                                  texture2d<float> tex [[texture(0)]]) {
            int2 coord = int2(
                (pos.x + 1.0) * 0.5 * float(tex.get_width()),
                (1.0 - pos.y) * 0.5 * float(tex.get_height())
            );
            coord = clamp(coord, int2(0), int2(tex.get_width()-1, tex.get_height()-1));
            return tex.read(uint2(coord));
        }
        """
        
        guard let device = self.device,
              let blitLib = try? device.makeLibrary(source: blitSource, options: nil),
              let blitVert = blitLib.makeFunction(name: "blit_vert"),
              let blitFrag = blitLib.makeFunction(name: "blit_frag"),
              let blitPipeline = try? device.makeRenderPipelineState(vertexFunction: blitVert, fragmentFunction: blitFrag) else {
            return
        }
        
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = drawable.texture
        renderPass.colorAttachments[0].loadAction = .load
        renderPass.colorAttachments[0].storeAction = .store
        
        guard let renderEncoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        renderEncoder.setRenderPipelineState(blitPipeline)
        renderEncoder.setFragmentTexture(self.sceneTex, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        encoder.endEncoding()
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
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
