import Foundation
import AppKit
import simd

// MARK: - Orbital camera controller

struct Camera {
    var position: SIMD3<Float>
    var yaw: Float       // horizontal angle around target
    var pitch: Float     // vertical angle from horizontal plane
    var distance: Float  // distance from target
    var target: SIMD3<Float>

    init() {
        self.position = SIMD3<Float>(0, 2, -20)
        self.yaw = 0
        self.pitch = 0.2
        self.distance = 20
        self.target = SIMD3<Float>(0, 0, 0)
        updateOrientation()
    }

    mutating func orbit(dx: Float, dy: Float) {
        yaw   += dx * 0.005
        pitch  = max(-.pi/2 + 0.01, min(.pi/2 - 0.01, pitch - dy * 0.005))
    }

    mutating func zoom(_ delta: Float) {
        distance = max(2, min(250, distance - delta * 1.5))
    }

    mutating func pan(dx: Float, dy: Float, right: SIMD3<Float>, up: SIMD3<Float>) {
        let scale = distance * 0.002
        target += right * dx * scale
        target += up * dy * scale
    }

    mutating func updateOrientation() {
        let cosPitch = cos(pitch)
        position = target + SIMD3<Float>(
            cos(yaw) * cosPitch,
            sin(pitch),
            sin(yaw) * cosPitch
        ) * distance
    }

    /// Compute view matrix components needed by the shader
    mutating func viewMatrix() -> (camPos: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        updateOrientation()
        let forward = ((target - position)).normalized
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = cross(worldUp, forward).normalized
        if right.x*right.x + right.y*right.y + right.z*right.z < 1e-6 { right = SIMD3<Float>(1, 0, 0) }
        let up = cross(forward, right).normalized
        return (position, right, up, forward)
    }
}
