import Foundation
import CryptoKit

enum AuditRegression {
    private static func check(_ condition: Bool, _ message: String = "Audit regression") { precondition(condition, message) }

    static func verifyCancellation(file: URL, volume: Volume) async {
        let gate = AsyncStream<Void>.makeStream()
        let read = Task.detached {
            for await _ in gate.stream {}
            return Result { try Volume.read(file) }
        }
        read.cancel()
        gate.continuation.finish()
        switch await read.value {
        case .failure(is CancellationError): break
        default: fatalError("Cancelled file load returned a volume")
        }
        let archGate = AsyncStream<Void>.makeStream()
        let estimate = Task.detached { for await _ in archGate.stream {}; return AutomaticArches.estimate(in: volume) }
        estimate.cancel()
        archGate.continuation.finish()
        check(await estimate.value == StudyArches())
        print("PASS · cancelled volume loading and arch estimation do not publish results")
    }
    static func verify(in root: URL, phantom: Volume) throws {
        let folder = root.appendingPathComponent("audit-dicom", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("study.dcm")
        let data = DICOMFixture.image(z: [0, 1.3], values: Array(0...11))
        try data.write(to: file)
        let direct = try Volume.read(file), throughFolder = try Volume.read(folder)
        check(direct.fingerprint == throughFolder.fingerprint && direct.pixels == throughFolder.pixels)
        let legacy = DICOM.singleFileSeriesFingerprint(data)
        check(direct.matchesFingerprint(legacy) && throughFolder.matchesFingerprint(legacy))
        let notesRoot = root.appendingPathComponent("migration-notes", isDirectory: true)
        let currentStore = StudyStore(root: notesRoot, fingerprint: direct.fingerprint!)!
        let oldStore = StudyStore(root: notesRoot, fingerprint: legacy)!
        let display = SavedDisplay(width: 100, level: 50, zoom: 1)
        var current = StudyNotes(), old = StudyNotes()
        let mark = StudyBookmark(name: "canonical", display: display, location: .slice(plane: 0, index: 0))
        current.bookmarks = [mark]
        var conflicting = mark
        conflicting.name = "legacy variant"
        old.bookmarks = [conflicting]
        old.lastView = conflicting.viewingState
        try currentStore.write(current, replacing: StudyNotes(), volume: direct)
        try oldStore.write(old, replacing: StudyNotes(), volume: direct)
        let legacyBytes = try Data(contentsOf: oldStore.file)
        let migrated = try currentStore.read(volume: direct)
        check(migrated.bookmarks.count == 2 && Set(migrated.bookmarks.map(\.id)).count == 2)
        check(try currentStore.read(volume: throughFolder) == migrated)
        check(try Data(contentsOf: oldStore.file) == legacyBytes)
        var removed = migrated
        removed.bookmarks.removeAll { $0.name == "legacy variant" }
        try currentStore.write(removed, replacing: migrated, volume: direct)
        check(try currentStore.read(volume: direct).bookmarks.count == 1, "Migration resurrected an intentionally removed bookmark")
        var later = old
        later.bookmarks.append(StudyBookmark(name: "later old-app note", display: display, location: .slice(plane: 0, index: 1)))
        try oldStore.write(later, replacing: old, volume: direct)
        check(try currentStore.read(volume: direct).bookmarks.contains { $0.name == "later old-app note" })

        // Divergent manual, baseline and automatic geometry must remain recoverable,
        // including a measurement whose UUID was reused by the old identity.
        let template = SyntheticStudy.defaultArches(for: phantom).upper!
        func variant(_ axial: Int) -> SavedArch { SavedArch(nodes: template.nodes, axial: axial) }
        var canonicalGeometry = StudyNotes(), legacyGeometry = StudyNotes()
        canonicalGeometry.upper = variant(10)
        canonicalGeometry.baseline = StudyArches(upper: variant(11))
        canonicalGeometry.automaticArches = StudyArches(upper: variant(12))
        legacyGeometry.upper = variant(13)
        legacyGeometry.baseline = StudyArches(upper: variant(14))
        legacyGeometry.automaticArches = StudyArches(upper: variant(15))
        let pose = MPRPose(point: SIMD3(32.0, 32.0, 12.0))
        let location = StudyBookmark.Location.mpr(pose, plane: Plane.axial.rawValue, main: Plane.axial.rawValue)
        var measured = StudyBookmark(name: "Measured", display: display, location: location,
            ruler: .mpr(first: pose.point, second: pose.point + SIMD3(3.0, 4.0, 0.0)))
        canonicalGeometry.bookmarks = [measured]
        measured.ruler = .mpr(first: pose.point, second: pose.point + SIMD3(6.0, 8.0, 0.0))
        legacyGeometry.bookmarks = [measured]
        let geometries = try canonicalGeometry.mergingLegacy(legacyGeometry, volume: phantom)
        check(geometries.upper == canonicalGeometry.upper && geometries.baseline == canonicalGeometry.baseline &&
              geometries.automaticArches == canonicalGeometry.automaticArches)
        let recovered = geometries.bookmarks.compactMap { mark -> SavedArch? in
            if case .panorama(let saved) = mark.location { return saved.arch }; return nil
        }
        check([variant(13), variant(14), variant(15)].allSatisfy { recovered.contains($0) })
        let distances = geometries.bookmarks.compactMap { $0.ruler?.distance(in: phantom, at: $0.location) }.sorted()
        check(distances == [5, 10] && Set(geometries.bookmarks.map(\.id)).count == geometries.bookmarks.count)
        let geometryStore = StudyStore(root: root.appendingPathComponent("geometry-merge"), fingerprint: phantom.fingerprint!)!
        try geometryStore.write(geometries, replacing: StudyNotes(), volume: phantom)
        check(try geometryStore.read(volume: phantom) == geometries)

        var large = data
        let index = large.range(of: Data([0x20, 0, 0x0e, 0, 0x55, 0x49]))!.lowerBound
        var field = Data([9, 0, 0x10, 0, 0x4c, 0x4f, 8, 0]) + Data("AUDIT   ".utf8)
        field += Data([9, 0, 0x10, 0x10, 0x4f, 0x42, 0, 0])
        var size = UInt32(70_000).littleEndian
        withUnsafeBytes(of: &size) { field.append(contentsOf: $0) }
        field += Data(repeating: 0, count: 70_000)
        large.insert(contentsOf: field, at: index)
        try large.write(to: file)
        check(try Volume.read(folder).pixels == direct.pixels)
        try Data(large.prefix(66_000)).write(to: file)
        do { _ = try Volume.read(folder); fatalError("Truncated private element accepted") }
        catch DICOMError.damaged {}

        let inverted = Volume(width: phantom.width, height: phantom.height, depth: phantom.depth,
            spacing: phantom.spacing, oriented: true, windowWidth: phantom.windowWidth,
            windowCenter: 4095 - phantom.windowCenter, pixels: phantom.pixels.map { 4095 - $0 }, invertedGrayscale: true)
        let a = AutomaticArches.estimate(in: phantom), b = AutomaticArches.estimate(in: inverted)
        check(a.upper != nil && a.lower != nil && a == b, "MONOCHROME1 changed the proposed geometry")
        print("PASS · DICOM file/folder identity, lossless legacy merge, repeat/delete/update migration, large header and MONOCHROME1 parity")
    }
}
