import Metal
import simd

/// Simulation parameters passed from the host to the Metal compute kernel.
/// Layout is matched to the `Params` struct in BlackholeSimulator.metal (128 bytes).
struct SimParams {
    var rs:             Float     // Schwarzschild radius in sim units (must match Metal Params offset 0)
    var disk_r_in:      Float     // Inner disk radius in units of rs (must match Metal Params offset 4)
    var disk_r_out:     Float     // Outer disk radius in units of rs (must match Metal Params offset 8)
    var cam_pos:        SIMD3<Float>
    var cam_right:      SIMD3<Float>
    var cam_up:         SIMD3<Float>
    var cam_fwd:        SIMD3<Float>
    var time:           Float
    var exposure:       Float
    var nsteps:         Int32
    var disk_visible:   UInt32
    var bloom_on:       UInt32
    var _pad0:          Float
    var _pad1:          Float
    var image_width:    Int32
    var image_height:   Int32
}

extension SimParams {
    static let size: Int = MemoryLayout<SimParams>.stride
}

/// State that the host manages
struct SimState {
    var params: SimParams
    var massIndex: Int = 1
    var stepCountBase: Int = 256
    var frameCount: Int = 0

    init() {
        // Compute rs for 1 solar mass, then scale
        let M = 10.0  // nominal 10 solar masses
        let rsMeters = 2.0 * 6.674e-11 * (M * 1.989e30) / (299792458.0 * 299792458.0)
        // Display scale: rs ≈ 3 sim units for visible accretion disk
        let scale: Float = Float(rsMeters) / 3.0
        let rs = Float(rsMeters) / scale

        params = SimParams(
            rs: rs,
            disk_r_in: 3.0,
            disk_r_out: 15.0,
            cam_pos: SIMD3<Float>(20, 8, -3),
            cam_right: SIMD3<Float>(1, 0, 0),
            cam_up: SIMD3<Float>(0, 1, 0),
            cam_fwd: SIMD3<Float>(-0.919601, -0.367840, 0.137940),
            time: 0,
            exposure: 1.2,
            nsteps: Int32(stepCountBase),
            disk_visible: 1,
            bloom_on: 1,
            _pad0: 0,
            _pad1: 0,
            image_width: 1920,
            image_height: 1080
        )
    }

    mutating func nextMass() {
        massIndex = (massIndex + 1) % 2
        let massSolarMasses: [Float] = [10.0, 1_000_000_000.0]
        let M = massSolarMasses[massIndex]
        let rsMeters = 2.0 * 6.674e-11 * (M * 1.989e30) / (299792458.0 * 299792458.0)
        let scale: Float = Float(rsMeters) / 3.0
        params.rs = Float(rsMeters) / scale
    }

    mutating func toggleBloom() {
        params.bloom_on = params.bloom_on == 1 ? 0 : 1
    }

    mutating func toggleDisk() {
        params.disk_visible = params.disk_visible == 1 ? 0 : 1
    }

    mutating func adjustSteps(_ delta: Int) {
        let newSteps = max(64, min(512, stepCountBase + delta))
        stepCountBase = newSteps
        params.nsteps = Int32(newSteps)
    }

    mutating func updateCameraVectors() {
        // Recompute orthonormal camera basis on every update
        let fwd = ((SIMD3<Float>(0, 0, 0) - params.cam_pos)).normalized
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = cross(worldUp, fwd)
        if length(right) < 1e-6 {
            right = SIMD3<Float>(1.0, 0, 0)
        }
        right = right.normalized
        let actualUp = cross(fwd, right)
        params.cam_fwd = fwd
        params.cam_right = right
        params.cam_up = actualUp
    }
}

extension SimState {
    mutating func toParams(_ vm: CameraViewMatrix) -> SimParams {
        var p = params
        p.cam_pos = vm.pos
        p.cam_right = vm.right
        p.cam_up = vm.up
        p.cam_fwd = vm.fwd
        p.image_width = vm.imageWidth
        p.image_height = vm.imageHeight
        // Increment simulation time each frame (~60fps)
        p.time += 1.0 / 60.0
        params.time = p.time
        return p
    }
}

extension SIMD3 where Scalar == Float {
    var normalized: SIMD3<Scalar> {
        let len = sqrt(x*x + y*y + z*z)
        return len > 1e-10 ? self / len : self
    }
}
