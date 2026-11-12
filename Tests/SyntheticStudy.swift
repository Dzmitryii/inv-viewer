import Foundation

enum SyntheticStudy {
    static let width = 128
    static let height = 128
    static let depth = 58
    static let spacing = 0.5

    // Parametric coordinates used to generate the synthetic study and its example arches.
    static func archPoint(_ fraction: Double) -> SIMD2<Double> {
        let angle = Double.pi * fraction
        return SIMD2(32 - 23 * cos(angle), 50 - 36 * sin(angle))
    }

    static func defaultArches(for volume: Volume) -> StudyArches {
        guard volume.width == width, volume.height == height, volume.depth == depth,
              volume.spacing == [spacing, spacing, spacing] else { return StudyArches() }
        let nodes = (0...12).map { archPoint(Double($0) / 12) }
        return StudyArches(upper: SavedArch(nodes: nodes, axial: 38), lower: SavedArch(nodes: nodes, axial: 19))
    }
}
