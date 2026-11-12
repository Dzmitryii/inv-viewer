import CoreGraphics
import Foundation
import simd

enum PlanarDistance {
    static func millimeters(from first: SIMD2<Double>, to second: SIMD2<Double>, extent: SIMD2<Double>) -> Double {
        simd_length((second - first) * extent)
    }
}

struct ArchCurve: Sendable {
    let points: [SIMD2<Double>]
    let normals: [SIMD2<Double>]
    let step: Double
    var length: Double { step * Double(points.count - 1) }

    init?(nodes: [SIMD2<Double>], resolution: Double) {
        guard nodes.count >= 3, zip(nodes, nodes.dropFirst()).allSatisfy({ simd_distance($0, $1) >= 0.1 })
        else { return nil }

        // Flatten a centripetal Catmull–Rom spline, then sample at equal distances in mm.
        var path = [nodes[0]]
        var distances = [0.0]
        for i in 0..<(nodes.count - 1) {
            let b = nodes[i], c = nodes[i + 1]
            let a = i > 0 ? nodes[i - 1] : 2 * b - c
            let d = i + 2 < nodes.count ? nodes[i + 2] : 2 * c - b
            let tb = sqrt(simd_distance(a, b))
            let tc = tb + sqrt(simd_distance(b, c))
            let td = tc + sqrt(simd_distance(c, d))
            let segments = min(128, max(8, Int(ceil(simd_distance(b, c) / 0.1))))
            for j in 1...segments {
                let t = tb + (tc - tb) * Double(j) / Double(segments)
                func mix(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ start: Double, _ end: Double) -> SIMD2<Double> {
                    p + (q - p) * ((t - start) / (end - start))
                }
                let ab = mix(a, b, 0, tb), bc = mix(b, c, tb, tc), cd = mix(c, d, tc, td)
                let point = mix(mix(ab, bc, 0, tc), mix(bc, cd, tb, td), tb, tc)
                let delta = simd_distance(point, path.last!)
                if delta > 1e-9 {
                    path.append(point)
                    distances.append(distances.last! + delta)
                }
            }
        }
        let length = distances.last!
        guard length >= 0.2 else { return nil }
        let count = min(1536, max(2, Int(ceil(length / resolution)) + 1))
        let step = length / Double(count - 1)
        var segment = 1
        var points = [SIMD2<Double>]()
        points.reserveCapacity(count)
        for i in 0..<count {
            let target = Double(i) * step
            while segment < path.count - 1 && distances[segment] < target { segment += 1 }
            let f = (target - distances[segment - 1]) / (distances[segment] - distances[segment - 1])
            points.append(path[segment - 1] + f * (path[segment] - path[segment - 1]))
        }
        var normals = [SIMD2<Double>]()
        for i in points.indices {
            let tangent = points[min(i + 1, count - 1)] - points[max(i - 1, 0)]
            guard simd_length(tangent) > 1e-9 else { return nil }
            normals.append(simd_normalize(SIMD2(-tangent.y, tangent.x)))
        }
        self.points = points
        self.normals = normals
        self.step = step
    }
}

struct GrayWindow: Codable, Equatable, Sendable {
    let width: Double
    let center: Double

    func byte(_ value: Double) -> UInt8 {
        let scaled = (value - center + width / 2) * (255 / width)
        return UInt8(min(255, max(0, scaled)).rounded())
    }

    static func image(_ bytes: Data, columns: Int, rows: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

extension Volume {
    var archResolution: Double { max(0.08, min(spacing[0], spacing[1])) }
    var physicalHeight: Double { Double(depth) * spacing[2] }

    private struct Sample {
        let index: Int
        let nextRow: Int
        let nextColumn: Int
        let xFraction: Float
        let yFraction: Float

        func value(in pixels: UnsafeBufferPointer<UInt16>, plane: Int) -> Float {
            guard index >= 0 else { return 0 }
            let i = plane + index
            let upper = Float(pixels[i]) * (1 - xFraction) + Float(pixels[i + nextColumn]) * xFraction
            let lower = Float(pixels[i + nextRow]) * (1 - xFraction) +
                Float(pixels[i + nextRow + nextColumn]) * xFraction
            return upper * (1 - yFraction) + lower * yFraction
        }
    }

    private func sample(_ point: SIMD2<Double>) -> Sample {
        let x = point.x / spacing[0], y = point.y / spacing[1]
        guard (0...Double(width - 1)).contains(x), (0...Double(height - 1)).contains(y)
        else { return Sample(index: -1, nextRow: 0, nextColumn: 0, xFraction: 0, yFraction: 0) }
        let ix = Int(x), iy = Int(y)
        return Sample(index: iy * width + ix, nextRow: iy + 1 < height ? width : 0,
                      nextColumn: ix + 1 < width ? 1 : 0, xFraction: Float(x - Double(ix)),
                      yFraction: Float(y - Double(iy)))
    }

    func panoramicImage(_ curve: ArchCurve, thickness: Double, offset: Double, window: GrayWindow) -> CGImage? {
        let perColumn = thickness == 0 ? 1 : min(81, max(2, Int(ceil(thickness / archResolution))))
        var samples = [Sample]()
        samples.reserveCapacity(curve.points.count * perColumn)
        for i in curve.points.indices {
            for j in 0..<perColumn {
                let across = ((Double(j) + 0.5) / Double(perColumn) - 0.5) * thickness
                samples.append(sample(curve.points[i] + curve.normals[i] * (offset + across)))
            }
        }
        return reformat(columns: curve.points.count, samples: samples, perColumn: perColumn, window: window)
    }

    func crossImage(_ curve: ArchCurve, at index: Int, width: Double, offset: Double,
                    window: GrayWindow) -> CGImage? {
        let count = min(512, max(2, Int(ceil(width / archResolution))))
        let center = curve.points[index], normal = curve.normals[index]
        let samples = (0..<count).map { i in
            sample(center + normal * (offset + ((Double(i) + 0.5) / Double(count) - 0.5) * width))
        }
        return reformat(columns: count, samples: samples, perColumn: 1, window: window)
    }

    private func reformat(columns: Int, samples: [Sample], perColumn: Int, window: GrayWindow) -> CGImage? {
        var data = Data(count: columns * depth)
        let finished = pixels.withUnsafeBufferPointer { pixels in
            data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for row in 0..<depth {
                    if Task.isCancelled { return false }
                    let plane = (depth - 1 - row) * width * height
                    for column in 0..<columns {
                        var total: Float = 0
                        let start = column * perColumn
                        for i in start..<(start + perColumn) {
                            total += samples[i].value(in: pixels, plane: plane)
                        }
                        output[row * columns + column] = window.byte(Double(total) / Double(perColumn))
                    }
                }
                return true
            }
        }
        return finished ? GrayWindow.image(data, columns: columns, rows: depth) : nil
    }
}
