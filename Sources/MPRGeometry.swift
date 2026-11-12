import CoreGraphics
import Foundation
import simd

extension Plane {
    var normalAxis: Int { 2 - rawValue }
    var rightAxis: Int { self == .sagittal ? 1 : 0 }
    var downAxis: Int { self == .axial ? 1 : 2 }

    var normalVector: SIMD3<Double> {
        var vector = SIMD3<Double>.zero
        vector[normalAxis] = 1
        return vector
    }

    var rightVector: SIMD3<Double> {
        var vector = SIMD3<Double>.zero
        vector[rightAxis] = 1
        return vector
    }

    var downVector: SIMD3<Double> {
        var vector = SIMD3<Double>.zero
        vector[downAxis] = self == .axial ? 1 : -1
        return vector
    }
}

struct MPRPose: Codable, Equatable, Sendable {
    var point: SIMD3<Double>
    private(set) var quaternion = SIMD4<Double>(0, 0, 0, 1)
    private(set) var roll = SIMD3<Double>.zero

    var isStraight: Bool { quaternion == SIMD4(0, 0, 0, 1) && roll == .zero }

    func normal(for plane: Plane) -> SIMD3<Double> {
        simd_quatd(vector: quaternion).act(plane.normalVector)
    }

    func axes(for plane: Plane) -> (right: SIMD3<Double>, down: SIMD3<Double>) {
        let local = simd_quatd(angle: roll[plane.rawValue], axis: plane.normalVector)
        let orientation = simd_quatd(vector: quaternion) * local
        return (orientation.act(plane.rightVector), orientation.act(plane.downVector))
    }

    mutating func rotate(_ radians: Double, in plane: Plane) {
        let rotation = simd_quatd(angle: radians, axis: normal(for: plane))
        quaternion = simd_normalize(rotation * simd_quatd(vector: quaternion)).vector
        // Keep the manipulated image stationary as the other two planes turn through it.
        roll[plane.rawValue] = (roll[plane.rawValue] - radians).remainder(dividingBy: 2 * .pi)
    }

    func valid(in volume: Volume) -> Bool {
        volume.containsMPRPoint(point) && abs(simd_length(quaternion) - 1) < 1e-8 &&
            (0..<3).allSatisfy { abs(roll[$0]) <= Double.pi }
    }
}

struct MPRFrame: Equatable, Sendable {
    let right: SIMD3<Double>
    let down: SIMD3<Double>
    let normal: SIMD3<Double>
    let offset: Double
    let minimum: SIMD2<Double>
    let size: SIMD2<Double>
    let columns: Int
    let rows: Int

    init(_ volume: Volume, plane: Plane, pose: MPRPose) {
        (right, down) = pose.axes(for: plane)
        normal = pose.normal(for: plane)
        offset = simd_dot(normal, pose.point)
        let lo = volume.mprLower, hi = volume.mprUpper
        let center = (lo + hi) / 2
        let span = hi - lo
        size = SIMD2(simd_dot(abs(right), span), simd_dot(abs(down), span))
        minimum = SIMD2(simd_dot(right, center), simd_dot(down, center)) - size / 2
        if simd_distance(right, plane.rightVector) < 1e-10 && simd_distance(down, plane.downVector) < 1e-10 {
            let native = volume.sliceSize(plane)
            columns = native.width
            rows = native.height
        } else {
            let resolution = volume.spacing.min()!
            columns = Int(min(1536, max(1, ceil(size.x / resolution - 1e-8))))
            rows = Int(min(1536, max(1, ceil(size.y / resolution - 1e-8))))
        }
    }

    func location(_ unit: SIMD2<Double>) -> SIMD3<Double> {
        let position = minimum + unit * size
        return right * position.x + down * position.y + normal * offset
    }

    func project(_ point: SIMD3<Double>) -> SIMD2<Double> {
        let coordinates = SIMD2(simd_dot(right, point), simd_dot(down, point))
        return (coordinates - minimum) / size
    }

    var sideLabels: [String] {
        [-right, right, -down, down].map { vector in
            let axes = (0..<3).sorted { abs(vector[$0]) > abs(vector[$1]) }
            let letters = vector.x >= 0 ? ["L"] : ["R"]
            let labels = letters + [vector.y >= 0 ? "P" : "A", vector.z >= 0 ? "S" : "I"]
            return axes.filter { abs(vector[$0]) >= 0.22 }.map { labels[$0] }.joined()
        }
    }
}

extension Volume {
    var spacingVector: SIMD3<Double> { SIMD3(spacing[0], spacing[1], spacing[2]) }
    var voxelLimit: SIMD3<Double> { SIMD3(Double(width - 1), Double(height - 1), Double(depth - 1)) }
    var mprLower: SIMD3<Double> { -0.5 * spacingVector }
    var mprUpper: SIMD3<Double> { (voxelLimit + 0.5) * spacingVector }

    func containsMPRPoint(_ point: SIMD3<Double>) -> Bool {
        let lower = mprLower, upper = mprUpper
        return (0..<3).allSatisfy { (lower[$0] - 1e-8...upper[$0] + 1e-8).contains(point[$0]) }
    }

    func movedMPRPoint(_ point: SIMD3<Double>, along direction: SIMD3<Double>, by distance: Double) -> SIMD3<Double> {
        let lower = mprLower, upper = mprUpper
        var clipped = distance
        for axis in 0..<3 where abs(direction[axis]) > 1e-10 {
            let first = (lower[axis] - point[axis]) / direction[axis]
            let second = (upper[axis] - point[axis]) / direction[axis]
            clipped = min(max(first, second), max(min(first, second), clipped))
        }
        return point + direction * clipped
    }

    func interpolatedVoxel(_ point: SIMD3<Double>) -> Double? {
        pixels.withUnsafeBufferPointer {
            sampleMPR(point / spacingVector, limit: voxelLimit, pixels: $0)
        }
    }

    private func sampleMPR(_ voxel: SIMD3<Double>, limit: SIMD3<Double>,
                           pixels: UnsafeBufferPointer<UInt16>) -> Double? {
        guard voxel.x >= -0.50000001, voxel.x <= limit.x + 0.50000001,
              voxel.y >= -0.50000001, voxel.y <= limit.y + 0.50000001,
              voxel.z >= -0.50000001, voxel.z <= limit.z + 0.50000001 else { return nil }
        let value = simd_clamp(voxel, .zero, limit)
        let x = Int(value.x), y = Int(value.y), z = Int(value.z)
        let base = (z * height + y) * width + x
        let dx = x + 1 < width ? 1 : 0
        let dy = y + 1 < height ? width : 0
        let dz = z + 1 < depth ? width * height : 0
        let fx = value.x - Double(x), fy = value.y - Double(y), fz = value.z - Double(z)
        func row(_ index: Int) -> Double {
            Double(pixels[index]) * (1 - fx) + Double(pixels[index + dx]) * fx
        }
        let first = row(base) * (1 - fy) + row(base + dy) * fy
        let second = row(base + dz) * (1 - fy) + row(base + dz + dy) * fy
        let result = first * (1 - fz) + second * fz
        // Suppress sub-ULP drift at integer samples before applying the grayscale window.
        return abs(result - result.rounded()) < 1e-8 ? result.rounded() : result
    }

    func mprImage(_ frame: MPRFrame, gray: GrayWindow) -> CGImage? {
        // Native, voxel-centred planes already have the same sampling lattice.
        // Fractional and tilted planes still use trilinear interpolation.
        for plane in Plane.allCases where frame.right == plane.rightVector && frame.down == plane.downVector &&
            frame.normal == plane.normalVector {
            let position = frame.offset / spacing[plane.normalAxis]
            let rounded = position.rounded()
            if abs(position - rounded) < 1e-10, (0..<Double(sliceCount(plane))).contains(rounded) {
                return image(plane, index: Int(rounded), windowWidth: gray.width, center: gray.center)
            }
        }
        return interpolatedMPRImage(frame, gray: gray)
    }

    func interpolatedMPRImage(_ frame: MPRFrame, gray: GrayWindow) -> CGImage? {
        let columns = frame.columns, rows = frame.rows
        let step = frame.size / SIMD2(Double(columns), Double(rows))
        let spacing = spacingVector, limit = voxelLimit
        let start = frame.location(SIMD2(0.5 / Double(columns), 0.5 / Double(rows))) / spacing
        let columnStep = frame.right * step.x / spacing
        let rowStep = frame.down * step.y / spacing
        var data = Data(count: columns * rows)
        pixels.withUnsafeBufferPointer { pixels in
            data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for row in 0..<rows {
                    let first = start + Double(row) * rowStep
                    for column in 0..<columns {
                        let voxel = first + Double(column) * columnStep
                        if let value = sampleMPR(voxel, limit: limit, pixels: pixels) {
                            output[row * columns + column] = gray.byte(value)
                        }
                    }
                }
            }
        }
        return GrayWindow.image(data, columns: columns, rows: rows)
    }
}
