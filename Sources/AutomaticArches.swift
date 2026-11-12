import Foundation
import simd

/// Finds a starting curve from the scan's axial intensity data. The result is
/// an editable starting point, not a segmentation or a tooth identification.
enum AutomaticArches {
    static let revision = 4
    private static let angles = (0..<17).map { -1.65 + 3.3 * Double($0) / 16 }
    private static let rimDirections = (0..<16).map { i in
        let angle = 2 * Double.pi * Double(i) / 16
        return SIMD2(cos(angle), sin(angle))
    }

    private struct Shape {
        var center: Double
        var front: Double
        var radius: Double
        var depth: Double
        var flare: Double

        func point(_ angle: Double) -> SIMD2<Double> {
            let arm = max(0, (abs(angle) - 0.76) / 0.89)
            let lateral = flare * arm * arm * (angle < 0 ? -1 : 1)
            return SIMD2(center + radius * sin(angle) + lateral, front + depth * (1 - cos(angle)))
        }

        func normal(_ angle: Double) -> SIMD2<Double> {
            let dx = radius * cos(angle) + flare * 2 * max(0, abs(angle) - 0.76) / (0.89 * 0.89)
            return simd_normalize(SIMD2(-depth * sin(angle), dx))
        }
    }

    private struct Sample {
        let on: Int
        let inner: Int
        let outer: Int
    }

    private struct Template {
        let shape: Shape
        let samples: Range<Int>
        let lengthBonus: Float
    }

    private struct Fit {
        let shape: Shape
        let axial: Int
        let score: Float

        var arch: SavedArch {
            SavedArch(nodes: AutomaticArches.angles.map(shape.point), axial: axial)
        }
    }

    // Work in millimeters so the same search applies to different voxel sizes.
    private struct Grid {
        let width: Int
        let height: Int
        let xVoxels: [Int]
        let yVoxels: [Int]

        init(_ volume: Volume) {
            width = Int(Double(volume.width - 1) * volume.spacing[0]) + 1
            height = Int(Double(volume.height - 1) * volume.spacing[1]) + 1
            xVoxels = (0..<width).map { min(volume.width - 1, Int((Double($0) / volume.spacing[0]).rounded())) }
            yVoxels = (0..<height).map { min(volume.height - 1, Int((Double($0) / volume.spacing[1]).rounded())) }
        }

        func index(_ p: SIMD2<Double>) -> Int {
            let x = min(width - 1, max(0, Int(p.x.rounded())))
            let y = min(height - 1, max(0, Int(p.y.rounded())))
            return y * width + x
        }

        func sample(_ field: [Float], at point: SIMD2<Double>) -> Float {
            guard point.x >= 0, point.x < Double(width - 1),
                  point.y >= 0, point.y < Double(height - 1) else { return 0 }
            let x = Int(point.x), y = Int(point.y)
            let fx = Float(point.x - Double(x)), fy = Float(point.y - Double(y))
            let i = y * width + x
            let top = field[i] * (1 - fx) + field[i + 1] * fx
            let bottom = field[i + width] * (1 - fx) + field[i + width + 1] * fx
            return top * (1 - fy) + bottom * fy
        }

        func field(_ volume: Volume, at z: Int, band: Int, low: Float, high: Float) -> [Float] {
            let plane = volume.width * volume.height
            let levels = [max(0, z - band), z, min(volume.depth - 1, z + band)].map { $0 * plane }
            let scale = 1 / (high - low)
            var raw = [Float](repeating: 0, count: width * height)
            for (y, iy) in yVoxels.enumerated() {
                let row = iy * volume.width
                for (x, ix) in xVoxels.enumerated() {
                    let index = row + ix
                    let value = (Float(volume.analysisValue(volume.pixels[levels[0] + index])) +
                                 Float(volume.analysisValue(volume.pixels[levels[1] + index])) +
                                 Float(volume.analysisValue(volume.pixels[levels[2] + index]))) / 3
                    raw[y * width + x] = min(1, max(0, (value - low) * scale))
                }
            }

            // Average a small neighborhood. A thin cortical edge or an
            // isolated bright artifact should not score like a tooth row.
            var smooth = raw
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let i = y * width + x
                    var sum: Float = 0
                    for row in [i - width, i, i + width] {
                        sum += raw[row - 1] + raw[row] + raw[row + 1]
                    }
                    smooth[i] = sum / 9
                }
            }
            return smooth
        }
    }

    static func estimate(in volume: Volume) -> StudyArches {
        guard !Task.isCancelled else { return StudyArches() }
        let extent = SIMD3(Double(volume.width - 1), Double(volume.height - 1), Double(volume.depth - 1))
            * volume.spacingVector
        guard volume.oriented, (42...320).contains(extent.x), (40...320).contains(extent.y),
              (12...320).contains(extent.z), volume.depth >= 12,
              let contrast = intensityRange(volume) else { return StudyArches() }

        let grid = Grid(volume)
        var samples: [Sample] = []
        var templates: [Template] = []
        let middle = extent.x / 2
        for center in stride(from: max(16, middle - 21), to: min(extent.x - 16, middle + 22), by: 5.0) {
            if Task.isCancelled { return StudyArches() }
            for front in stride(from: 2.0, to: min(58, extent.y * 0.65), by: 4.0) {
                for radius in stride(from: 17.0, through: 33.0, by: 4.0) {
                    for depth in stride(from: 26.0, through: 51.0, by: 5.0) {
                        for flare in [0.0, 6, 12] {
                            let shape = Shape(center: center, front: front, radius: radius, depth: depth, flare: flare)
                            let start = samples.count
                            if let template = makeTemplate(shape, grid: grid, extent: SIMD2(extent.x, extent.y),
                                                           start: start, appendTo: &samples) {
                                templates.append(template)
                            }
                        }
                    }
                }
            }
        }
        guard !templates.isEmpty else { return StudyArches() }

        let step = max(1, Int((2 / volume.spacing[2]).rounded()), (volume.depth + 79) / 80)
        let band = max(1, Int((0.65 / volume.spacing[2]).rounded()))
        var fits: [Fit] = []
        for z in stride(from: 2, to: volume.depth - 2, by: step) {
            if Task.isCancelled { return StudyArches() }
            let field = grid.field(volume, at: z, band: band, low: contrast.low, high: contrast.high)
            var best: Fit?
            for template in templates {
                let score = quality(template, in: samples, field: field)
                if score >= 0.43, score > best?.score ?? 0 {
                    best = Fit(shape: template.shape, axial: z, score: score)
                }
            }
            if let best { fits.append(best) }
        }

        // Require a compatible pair of levels, ordered inferior to superior.
        // An isolated U-shaped bone contour does not establish which jaw it is.
        var pair: (lower: Fit, upper: Fit)?
        var bestPair: Float = 0
        for (index, lower) in fits.enumerated() {
            for upper in fits.dropFirst(index + 1) {
                let distance = Double(upper.axial - lower.axial) * volume.spacing[2]
                guard (6...22).contains(distance),
                      abs(upper.shape.center - lower.shape.center) <= 10,
                      abs(upper.shape.front - lower.shape.front) <= 13 else { continue }
                let score = (upper.score + lower.score) / 2 - Float(abs(distance - 11) * 0.03 / 8)
                if score > bestPair {
                    bestPair = score
                    pair = (lower, upper)
                }
            }
        }
        guard let pair else { return StudyArches() }
        let upper = refine(pair.upper.arch, in: volume, grid: grid, contrast: contrast,
                           slabOffsets: [2.5, 4.5, 6.5], end: volume.depth - 1)
        let lowerTrace = refine(pair.lower.arch, in: volume, grid: grid, contrast: contrast,
                                slabOffsets: [4.5, 6.5, 8.5], end: pair.upper.axial - 1)
        let lower = centerLowerEnds(lowerTrace, in: volume, grid: grid, contrast: contrast,
                                    below: pair.upper.axial)
        let arches = StudyArches(upper: upper, lower: lower)
        return arches.valid(in: volume) ? arches : StudyArches()
    }

    private static func centerLowerEnds(_ arch: SavedArch, in volume: Volume, grid: Grid,
                                        contrast: (low: Float, high: Float), below upper: Int) -> SavedArch {
        let spacing = volume.spacing[2]
        let band = max(1, Int((0.65 / spacing).rounded()))
        let levels = Set([6.0, 8, 10, 12].map { min(upper - 1 - band, arch.axial + Int(($0 / spacing).rounded())) })
        guard levels.count >= 3 else { return arch }
        let fields = levels.sorted().map { grid.field(volume, at: $0, band: band, low: contrast.low, high: contrast.high) }
        var nodes = arch.nodes
        for first in [true, false] {
            let end = first ? 0 : nodes.count - 1
            let neighbor = first ? 1 : end - 1
            if let fit = terminalCenter(near: nodes[end], after: nodes[neighbor], fields: fields, grid: grid) {
                nodes[end] = fit.point
                // A nearby control point on the old ridge can make the end hook sideways.
                if simd_distance(fit.point, nodes[neighbor]) < 5 { nodes.remove(at: neighbor) }
                let preceding = nodes[first ? 1 : nodes.count - 2]
                let tangent = simd_normalize(fit.point - preceding)
                // Keep the posterior half of the tooth in the reconstruction.
                nodes.insert(fit.point + fit.radius * tangent, at: first ? 0 : nodes.count)
            }
        }
        let centered = SavedArch(nodes: nodes, axial: arch.axial)
        return centered.valid(in: volume) ? centered : arch
    }

    private static func terminalCenter(near seed: SIMD2<Double>, after neighbor: SIMD2<Double>,
                                       fields: [[Float]], grid: Grid) -> (point: SIMD2<Double>, radius: Double)? {
        // Favor levels toward the crowns, while requiring support on more than one level.
        func score(_ center: SIMD2<Double>) -> (mean: Float, supported: Int, radius: Double) {
            var total: Float = 0
            var supported = 0
            var radii = 0.0
            for (index, field) in fields.enumerated() {
                let rim = bestRim(around: center, field: field, grid: grid)
                total += index < fields.count / 2 ? rim.score : 2 * rim.score
                if rim.score >= 0.26 {
                    supported += 1
                    radii += rim.radius
                }
            }
            return (total / Float(2 * fields.count - fields.count / 2), supported, radii / Double(max(1, supported)))
        }
        let threshold = max(0.27, score(seed).mean + 0.055)
        var best = (score: threshold, point: seed, radius: 0.0)
        for dy in stride(from: -7.0, through: 3.5, by: 0.5) where seed.y + dy >= neighbor.y + 1 {
            for dx in stride(from: -7.0, through: 7.0, by: 0.5) {
                let shift = hypot(dx, dy)
                guard shift <= 7 else { continue }
                let point = seed + SIMD2(dx, dy)
                guard (9...Double(grid.width - 10)).contains(point.x),
                      (9...Double(grid.height - 10)).contains(point.y) else { continue }
                let contour = score(point)
                let value = contour.mean - 0.010 * Float(shift)
                if contour.supported >= 2, value > best.score { best = (value, point, contour.radius) }
            }
        }
        // Small shifts can reflect normal variation in the cross-section rather than a missed center.
        return simd_distance(best.point, seed) >= 3.5 ? (best.point, best.radius) : nil
    }

    private static func bestRim(around point: SIMD2<Double>, field: [Float], grid: Grid) -> (score: Float, radius: Double) {
        let core = grid.sample(field, at: point)
        var best = (score: Float(0), radius: 0.0)
        for radius in [3.5, 4.5, 5.5] {
            var rim: [Float] = []
            var outside: Float = 0
            for direction in rimDirections {
                let inner = grid.sample(field, at: point + (radius - 0.75) * direction)
                let middle = grid.sample(field, at: point + radius * direction)
                let outer = grid.sample(field, at: point + (radius + 0.75) * direction)
                rim.append(max(inner, middle, outer))
                outside += grid.sample(field, at: point + (radius + 2.75) * direction)
            }
            // Reward a rim visible on several sides, including its weakest sectors.
            let mean = rim.reduce(0, +) / Float(rim.count)
            let weak = rim.sorted().prefix(5).reduce(0, +) / 5
            let value = 0.50 * (mean + weak) - 0.34 * outside / Float(rim.count) - 0.09 * core
            if value > best.score { best = (value, radius) }
        }
        return best
    }

    private static func refine(_ arch: SavedArch, in volume: Volume, grid: Grid,
                               contrast: (low: Float, high: Float), slabOffsets: [Double], end: Int) -> SavedArch {
        // Posterior teeth may sit above the axial level that best fits the front.
        // Keep the lower projection below the upper fit so the two rows do not mix.
        let spacing = volume.spacing[2]
        let band = max(1, Int((1 / spacing).rounded()))
        let levels = Set(slabOffsets.map { min(end - band, arch.axial + Int(($0 / spacing).rounded())) })
        guard levels.count >= 2 else { return arch }
        var density = [Float](repeating: 0, count: grid.width * grid.height)
        for level in levels.sorted() {
            let slab = grid.field(volume, at: level, band: band, low: contrast.low, high: contrast.high)
            for i in density.indices { density[i] += slab[i] / Float(levels.count) }
        }

        // Broad local support favors tooth-sized structures over narrow cortical edges.
        let broad = smoothAcrossRow(density, grid: grid, radius: 5)
        let center = arch.nodes.dropFirst(4).dropLast(4)
        let rightAnchor = center.first!, rightEnd = arch.nodes.first!
        let leftAnchor = center.last!, leftEnd = arch.nodes.last!
        var right = posteriorPath(from: rightAnchor, to: rightEnd, outward: -1, in: broad, grid: grid)
        var left = posteriorPath(from: leftAnchor, to: leftEnd, outward: 1, in: broad, grid: grid)
        if right == nil || left == nil {
            // The fitted slice may already show the crowns, especially on a flat arch.
            let fitted = grid.field(volume, at: arch.axial, band: band, low: contrast.low, high: contrast.high)
            let local = smoothAcrossRow(fitted, grid: grid, radius: 2)
            right = right ?? posteriorPath(from: rightAnchor, to: rightEnd, outward: -1, in: local, grid: grid)
            left = left ?? posteriorPath(from: leftAnchor, to: leftEnd, outward: 1, in: local, grid: grid)
        }
        let nodes = (right.map { Array($0.reversed()) } ?? Array(arch.nodes.prefix(4))) +
            Array(center) + (left ?? Array(arch.nodes.suffix(4)))
        let refined = SavedArch(nodes: nodes, axial: arch.axial)
        return refined.valid(in: volume) ? refined : arch
    }

    private static func smoothAcrossRow(_ density: [Float], grid: Grid, radius: Int) -> [Float] {
        var smoothed = density
        for y in 0..<grid.height {
            let row = y * grid.width
            var sum = density[row..<(row + radius)].reduce(0, +)
            for x in 0..<grid.width {
                if x + radius < grid.width { sum += density[row + x + radius] }
                let count = min(grid.width - 1, x + radius) - max(0, x - radius) + 1
                smoothed[row + x] = sum / Float(count)
                if x >= radius { sum -= density[row + x - radius] }
            }
        }
        return smoothed
    }

    private static func posteriorPath(from anchor: SIMD2<Double>, to fallback: SIMD2<Double>, outward: Int,
                                      in density: [Float], grid: Grid) -> [SIMD2<Double>]? {
        let x0 = Int(anchor.x.rounded())
        let y0 = Int(anchor.y.rounded())
        let lo = max(2, x0 + (outward < 0 ? -23 : -6))
        let hi = min(grid.width - 3, x0 + (outward > 0 ? 23 : 6))
        let end = min(grid.height - 3, Int(fallback.y.rounded()) + 14, y0 + 56)
        guard lo <= hi, (lo...hi).contains(x0), y0 + 2 <= end else { return nil }

        // Track each side independently. Continuous support adds to the path score;
        // short gaps can be crossed, while long gaps stop the search.
        var previous = [Float](repeating: -.infinity, count: grid.width)
        var gaps = [Int](repeating: 0, count: grid.width)
        previous[x0] = 0
        var parents: [[Int]] = []
        var best: (score: Float, row: Int, column: Int, support: Float) = (0.55, -1, x0, 0)
        func support(at x: Int, in row: Int) -> Float {
            let left = density[row + max(0, x - 10)]
            let right = density[row + min(grid.width - 1, x + 10)]
            return density[row + x] - 0.15 * (left + right)
        }
        for y in stride(from: y0 + 2, through: end, by: 2) {
            let row = y * grid.width
            var next = [Float](repeating: -.infinity, count: grid.width)
            var nextGaps = gaps
            var parent = [Int](repeating: -1, count: grid.width)
            for x in lo...hi {
                let ridge = support(at: x, in: row)
                let supported = ridge >= 0.265
                for px in max(lo, x - 3)...min(hi, x + 3) where gaps[px] < 4 || supported {
                    let score = previous[px] + ridge - 0.265 - 0.045 * Float(abs(x - px))
                    if score > next[x] {
                        next[x] = score
                        parent[x] = px
                        nextGaps[x] = supported ? 0 : gaps[px] + 1
                    }
                }
                if supported, parents.count >= 3, next[x] > best.score {
                    best = (next[x], parents.count, x, ridge)
                }
            }
            parents.append(parent)
            previous = next
            gaps = nextGaps
        }
        guard best.row >= 0 else { return nil }
        var lastRow = best.row
        var x = best.column
        let parent = parents[lastRow][x]
        let previousSupport = support(at: parent, in: (y0 + 2 * lastRow) * grid.width)
        // A weak falling edge can be a continuation into bone. Stop on the preceding ridge.
        if best.support < 0.34, previousSupport > best.support + 0.03 {
            lastRow -= 1
            x = parent
        }
        var tail: [SIMD2<Double>] = []
        for row in stride(from: lastRow, through: 0, by: -1) {
            if row == lastRow || (row % 3 == 2 && row <= lastRow - 2) {
                tail.append(SIMD2(Double(x), Double(y0 + 2 * (row + 1))))
            }
            x = parents[row][x]
        }
        return tail.reversed()
    }

    private static func intensityRange(_ volume: Volume) -> (low: Float, high: Float)? {
        var values: [UInt16] = []
        for z in stride(from: 0, to: volume.depth, by: max(1, volume.depth / 64)) {
            for y in stride(from: 0, to: volume.height, by: max(1, volume.height / 64)) {
                let row = (z * volume.height + y) * volume.width
                for x in stride(from: 0, to: volume.width, by: max(1, volume.width / 64)) {
                    values.append(volume.analysisValue(volume.pixels[row + x]))
                }
            }
        }
        values.sort()
        let low = Float(values[Int(Double(values.count - 1) * 0.85)])
        let high = Float(values[Int(Double(values.count - 1) * 0.995)])
        return high - low > 16 ? (low, high) : nil
    }

    private static func makeTemplate(_ shape: Shape, grid: Grid, extent: SIMD2<Double>,
                                     start: Int, appendTo samples: inout [Sample]) -> Template? {
        // The template is widest at the posterior ends. Its anterior point
        // and both posterior endpoints bound the remaining samples.
        let endpoint = shape.point(1.65)
        let opposite = shape.point(-1.65)
        // A non-flared ellipse reaches its widest point slightly before its end.
        let halfWidth = max(shape.radius, endpoint.x - shape.center)
        guard shape.center - halfWidth >= 2, shape.center + halfWidth <= extent.x - 2,
              endpoint.y <= extent.y - 2 else { return nil }

        var length = 0.0
        var previous = opposite
        for angle in angles {
            let point = shape.point(angle)
            let direction = 7 * shape.normal(angle)
            samples.append(Sample(on: grid.index(point), inner: grid.index(point + direction),
                                  outer: grid.index(point - direction)))
            length += simd_distance(previous, point)
            previous = point
        }
        let bonus = Float(min(65, max(0, length - 75)) * 0.0032)
        return Template(shape: shape, samples: start..<samples.count, lengthBonus: bonus)
    }

    private static func quality(_ template: Template, in samples: [Sample], field: [Float]) -> Float {
        var total: Float = 0
        var surroundings: Float = 0
        var left: Float = 0
        var front: Float = 0
        var right: Float = 0
        var covered = 0
        for (i, index) in template.samples.enumerated() {
            let sample = samples[index]
            let value = field[sample.on]
            total += value
            surroundings += (field[sample.inner] + field[sample.outer]) / 2
            if value > 0.21 { covered += 1 }
            if i < 6 { left += value }
            else if i < 11 { front += value }
            else { right += value }
        }
        // Evidence must be present on both sides and across the front.
        guard covered >= 12, left >= 6 * 0.19, front >= 5 * 0.19, right >= 6 * 0.19 else { return 0 }
        let count = Float(template.samples.count)
        let coverage = Float(covered) / count
        let evidence = (total - 0.28 * surroundings) / count * (0.65 + 0.35 * coverage)
            - 0.14 * abs(left - right) / 6
        guard evidence >= 0.31 else { return 0 }
        return evidence + template.lengthBonus
    }
}
