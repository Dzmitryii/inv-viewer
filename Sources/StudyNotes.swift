import Foundation
import CryptoKit
import simd

struct SavedArch: Codable, Equatable {
    let nodes: [SIMD2<Double>]
    let axial: Int

    // The patient right endpoint appears first even for reverse drawing order.
    static func orderedNodes(_ nodes: [SIMD2<Double>]) -> [SIMD2<Double>] {
        if let first = nodes.first, let last = nodes.last, first.x > last.x { return Array(nodes.reversed()) }
        return nodes
    }

    func valid(in volume: Volume) -> Bool {
        let limit = volume.voxelLimit * volume.spacingVector
        return (3...40).contains(nodes.count) && (0..<volume.depth).contains(axial) &&
            nodes.allSatisfy { (0...limit.x).contains($0.x) && (0...limit.y).contains($0.y) } &&
            ArchCurve(nodes: nodes, resolution: volume.archResolution) != nil
    }
}

struct StudyArches: Codable, Equatable {
    var upper: SavedArch?
    var lower: SavedArch?

    func valid(in volume: Volume) -> Bool {
        (upper?.valid(in: volume) ?? true) && (lower?.valid(in: volume) ?? true)
    }
}

struct SavedPanorama: Codable, Equatable {
    let jaw: Int
    let arch: SavedArch
    let section: Int
    let thickness: Double
    let offset: Double
    let widthIndex: Int
    let intervalIndex: Int
    let detailed: Bool
    let showSections: Bool
    let showGuides: Bool

    func valid(in volume: Volume) -> Bool {
        guard (0...1).contains(jaw), arch.valid(in: volume), (0..<1536).contains(section),
              (0...20).contains(thickness), (-10...10).contains(offset),
              (0...2).contains(widthIndex), (0...2).contains(intervalIndex) else { return false }
        return ArchCurve(nodes: arch.nodes, resolution: volume.archResolution)?.points.indices.contains(section) == true
    }
}

struct SavedDisplay: Codable, Equatable {
    var valid: Bool { (1...65535).contains(width) && (0...65535).contains(level) && (1...4).contains(zoom) }
    let width: Double
    let level: Double
    let zoom: Double
}

enum SavedRuler: Codable, Equatable {
    case mpr(first: SIMD3<Double>, second: SIMD3<Double>)
    case section(first: SIMD2<Double>, second: SIMD2<Double>)

    func distance(in volume: Volume, at location: StudyBookmark.Location) -> Double? {
        switch (self, location) {
        case let (.mpr(first, second), .mpr(pose, rawPlane, _)):
            guard let plane = Plane(rawValue: rawPlane), pose.valid(in: volume) else { return nil }
            let frame = MPRFrame(volume, plane: plane, pose: pose)
            guard [first, second].allSatisfy({
                volume.containsMPRPoint($0) && abs(simd_dot(frame.normal, $0) - frame.offset) < 1e-7
            }) else { return nil }
            return simd_distance(first, second)
        case let (.section(first, second), .panorama(saved)):
            guard saved.detailed, saved.valid(in: volume),
                  let curve = ArchCurve(nodes: SavedArch.orderedNodes(saved.arch.nodes), resolution: volume.archResolution) else { return nil }
            let width = [20.0, 30, 40][saved.widthIndex]
            guard [first, second].allSatisfy({ unit in
                guard (0...1).contains(unit.x), (0...1).contains(unit.y) else { return false }
                let xy = curve.points[saved.section] + curve.normals[saved.section] *
                    (saved.offset + (unit.x - 0.5) * width)
                let z = ((1 - unit.y) * Double(volume.depth) - 0.5) * volume.spacing[2]
                return volume.containsMPRPoint(SIMD3(xy.x, xy.y, z))
            }) else { return nil }
            return PlanarDistance.millimeters(from: first, to: second, extent: SIMD2(width, volume.physicalHeight))
        default: return nil
        }
    }
}

struct StudyBookmark: Codable, Equatable, Identifiable {
    enum Location: Codable, Equatable {
        case slice(plane: Int, index: Int)
        case panorama(SavedPanorama)
        case mpr(MPRPose, plane: Int, main: Int)

        var isPanorama: Bool {
            if case .panorama = self { return true }
            return false
        }

        func valid(in volume: Volume) -> Bool {
            switch self {
            case .slice(let plane, let index):
                guard let plane = Plane(rawValue: plane) else { return false }
                return (0..<volume.sliceCount(plane)).contains(index)
            case .panorama(let panorama): return panorama.valid(in: volume)
            case .mpr(let pose, let plane, let main):
                return Plane(rawValue: plane) != nil && Plane(rawValue: main) != nil && pose.valid(in: volume)
            }
        }
    }

    var id = UUID()
    var name: String
    let display: SavedDisplay
    let location: Location
    var ruler: SavedRuler? = nil
    var annotation: String? = nil

    var viewingState: SavedViewingState { SavedViewingState(display: display, location: location, ruler: ruler) }

    static func validAnnotation(_ text: String) -> Bool {
        text.utf8.count <= 2048 && !text.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\t"
        }
    }

    func valid(in volume: Volume) -> Bool {
        (1...80).contains(name.count) && name.utf8.count <= 512 &&
            (annotation.map(Self.validAnnotation) ?? true) && viewingState.valid(in: volume)
    }
}

struct SavedViewingState: Codable, Equatable {
    let display: SavedDisplay
    let location: StudyBookmark.Location
    let ruler: SavedRuler?

    func valid(in volume: Volume) -> Bool {
        display.valid && location.valid(in: volume) &&
            (ruler == nil || ruler?.distance(in: volume, at: location) != nil)
    }
}

struct StudyNotes: Codable, Equatable {
    let version: Int
    var baseline: StudyArches?
    var automaticArches: StudyArches?
    var automaticArchRevision: Int?
    var upper: SavedArch?
    var lower: SavedArch?
    var bookmarks: [StudyBookmark]
    var lastView: SavedViewingState?
    var lastBookmark: UUID?
    var migratedSources: [String: String]?

    init() {
        version = 1
        bookmarks = []
    }

    var needsAutomaticArches: Bool {
        automaticArchRevision != AutomaticArches.revision &&
            (automaticArches != nil || (baseline?.upper == nil && upper == nil) ||
             (baseline?.lower == nil && lower == nil))
    }

    func withAutomaticArches(_ arches: StudyArches) -> StudyNotes {
        var updated = self
        updated.automaticArches = arches
        updated.automaticArchRevision = AutomaticArches.revision
        // Ordinary resume state may contain a copy of the old suggestion.
        // Keep bookmarks, measurements, and manually traced curves exact.
        if lastBookmark == nil, let lastView, lastView.ruler == nil,
           case .panorama(let panorama) = lastView.location {
            let isUpper = panorama.jaw == 0
            let manual = isUpper ? upper : lower
            let preset = isUpper ? baseline?.upper : baseline?.lower
            let previous = isUpper ? automaticArches?.upper : automaticArches?.lower
            let replacement = isUpper ? arches.upper : arches.lower
            if manual == nil, preset == nil, previous?.nodes == panorama.arch.nodes,
               replacement?.nodes != previous?.nodes {
                updated.lastView = nil
            }
        }
        return updated
    }

    func valid(in volume: Volume) -> Bool {
        version == 1 && (lastView?.valid(in: volume) ?? true) &&
            (migratedSources?.count ?? 0) <= 128 &&
            (migratedSources?.allSatisfy { StudyStore.validFingerprint($0.key) && StudyStore.validFingerprint($0.value) } ?? true) &&
            (lastBookmark.map { id in bookmarks.contains { $0.id == id } } ?? true) && (baseline?.valid(in: volume) ?? true) &&
            (automaticArches?.valid(in: volume) ?? true) &&
            StudyArches(upper: upper, lower: lower).valid(in: volume) &&
            bookmarks.count <= 100 && Set(bookmarks.map(\.id)).count == bookmarks.count &&
            bookmarks.allSatisfy { $0.valid(in: volume) }
    }
}

enum StudyStoreError: LocalizedError {
    case invalid, changed, mergeLimit

    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "Отметки или дуги имеют неподдерживаемый формат.")
        case .changed: String(localized: "Другой экземпляр изменил отметки или дугу. Откройте снимок заново.")
        case .mergeLimit: String(localized: "Для объединения недостаточно места в списке отметок. Сохранённые файлы не изменены. Уменьшите число отметок и повторите.")
        }
    }
}

struct StudyStore {
    let file: URL

    init?(root: URL, fingerprint: String) {
        guard Self.validFingerprint(fingerprint) else { return nil }
        file = root.appendingPathComponent(fingerprint + ".json")
    }

    static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private var document: LocalDocument<StudyNotes> { LocalDocument(file: file, limit: 1_048_576) }

    func read(volume: Volume) throws -> StudyNotes {
        let previous = try document.read(default: StudyNotes()) { $0.valid(in: volume) }
        var result = previous
        for alias in volume.legacyFingerprints where alias != file.deletingPathExtension().lastPathComponent {
            guard let source = StudyStore(root: file.deletingLastPathComponent(), fingerprint: alias),
                  FileManager.default.fileExists(atPath: source.file.path) else { continue }
            let old = try source.document.read(default: StudyNotes()) { $0.valid(in: volume) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let digest = SHA256.hash(data: try encoder.encode(old)).map { String(format: "%02x", $0) }.joined()
            guard result.migratedSources?[alias] != digest else { continue }
            result = try result.mergingLegacy(old, volume: volume)
            if result.migratedSources == nil { result.migratedSources = [:] }
            result.migratedSources?[alias] = digest
        }
        if result != previous {
            try document.write(result, replacing: previous, default: StudyNotes()) { $0.valid(in: volume) }
        }
        return result
    }

    func write(_ notes: StudyNotes, replacing previous: StudyNotes, volume: Volume) throws {
        try document.write(notes, replacing: previous, default: StudyNotes()) { $0.valid(in: volume) }
    }
}

extension StudyNotes {
    // Keep the canonical choice and retain divergent saved geometry as bookmarks.
    // Source documents are never removed or rewritten by the migration.
    func mergingLegacy(_ other: StudyNotes, volume: Volume) throws -> StudyNotes {
        guard valid(in: volume), other.valid(in: volume) else { throw StudyStoreError.invalid }
        if self == StudyNotes() { return other }
        var result = self
        func retain(_ mark: StudyBookmark) throws {
            if result.bookmarks.contains(where: {
                $0.name == mark.name && $0.annotation == mark.annotation && $0.viewingState == mark.viewingState
            }) { return }
            guard result.bookmarks.count < 100 else { throw StudyStoreError.mergeLimit }
            var copy = mark
            if result.bookmarks.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
            result.bookmarks.append(copy)
        }
        for mark in other.bookmarks { try retain(mark) }
        let title = String(localized: "Восстановленный вариант")
        let display = SavedDisplay(width: min(65535, max(1, volume.windowWidth)),
                                   level: min(65535, max(0, volume.windowCenter)), zoom: 1)
        func arch(_ current: SavedArch?, _ incoming: SavedArch?, jaw: Int) throws -> SavedArch? {
            guard let incoming else { return current }
            guard let current else { return incoming }
            if current != incoming {
                let position = SavedPanorama(jaw: jaw, arch: incoming, section: 0, thickness: 8, offset: 0,
                    widthIndex: 1, intervalIndex: 1, detailed: false, showSections: true, showGuides: true)
                try retain(StudyBookmark(name: title, display: display, location: .panorama(position)))
            }
            return current
        }
        result.upper = try arch(upper, other.upper, jaw: 0)
        result.lower = try arch(lower, other.lower, jaw: 1)
        let baselineUpper = try arch(baseline?.upper, other.baseline?.upper, jaw: 0)
        let baselineLower = try arch(baseline?.lower, other.baseline?.lower, jaw: 1)
        if baselineUpper != nil || baselineLower != nil {
            result.baseline = StudyArches(upper: baselineUpper, lower: baselineLower)
        }
        let autoUpper = try arch(automaticArches?.upper, other.automaticArches?.upper, jaw: 0)
        let autoLower = try arch(automaticArches?.lower, other.automaticArches?.lower, jaw: 1)
        if autoUpper != nil || autoLower != nil {
            result.automaticArches = StudyArches(upper: autoUpper, lower: autoLower)
            if automaticArches == nil { result.automaticArchRevision = other.automaticArchRevision }
        }
        if let incoming = other.lastView {
            if result.lastView == nil {
                result.lastView = incoming
                // UUID may have been remapped; resume the view without a mismatched annotation.
                result.lastBookmark = nil
            } else if result.lastView != incoming {
                try retain(StudyBookmark(name: title, display: incoming.display, location: incoming.location,
                                         ruler: incoming.ruler))
            }
        }
        guard result.valid(in: volume) else { throw StudyStoreError.invalid }
        return result
    }
}
