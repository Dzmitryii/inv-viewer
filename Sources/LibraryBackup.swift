import CryptoKit
import Foundation
import simd

enum BackupError: LocalizedError {
    case invalid, conflict(String)
    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "Резервная копия повреждена, слишком велика или имеет неподдерживаемый формат.")
        case .conflict(let item): String(localized: "В резервной копии и на этом Mac есть разные версии записи: \(item). Импорт не выполнен; существующие данные сохранены.")
        }
    }
}

struct LibraryBackup: Codable, Equatable {
    var version = 1
    var library: StudyLibrary
    var studies: [String: StudyNotes]

    private struct Envelope: Codable {
        let format: String
        let checksum: String
        let contents: LibraryBackup
    }
    static let byteLimit = 64 * 1024 * 1024

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func validate() throws {
        guard version == 1, library.valid, studies.count <= 4096,
              try Self.encoded(library).count <= 16 * 1024 * 1024 else { throw BackupError.invalid }
        for (key, notes) in studies {
            guard StudyStore.validFingerprint(key), notes.portableValid,
                  try Self.encoded(notes).count <= 1_048_576 else { throw BackupError.invalid }
        }
    }

    func data() throws -> Data {
        try validate()
        let payload = try Self.encoded(self)
        let checksum = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let result = try Self.encoded(Envelope(format: "INV-Viewer-backup-1", checksum: checksum, contents: self))
        guard result.count <= Self.byteLimit else { throw BackupError.invalid }
        return result
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= byteLimit else { throw BackupError.invalid }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        let expected = SHA256.hash(data: try encoded(envelope.contents)).map { String(format: "%02x", $0) }.joined()
        guard envelope.format == "INV-Viewer-backup-1", envelope.checksum == expected else { throw BackupError.invalid }
        try envelope.contents.validate()
        return envelope.contents
    }

    static func snapshot(at root: URL) throws -> Self {
        try StoreAccess.locked(root) {
            let library = try StudyLibrary.store(at: root).readUnlocked(default: StudyLibrary(), valid: { $0.valid })
            var studies: [String: StudyNotes] = [:]
            let folder = root.appendingPathComponent("Studies", isDirectory: true)
            let files: [URL]
            if FileManager.default.fileExists(atPath: folder.path) {
                files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            } else { files = [] }
            var total = 0
            for file in files where file.pathExtension == "json" {
                let key = file.deletingPathExtension().lastPathComponent
                guard StudyStore.validFingerprint(key), studies.count < 4096,
                      let data = try StoreAccess.read(file, limit: 1_048_576) else { throw BackupError.invalid }
                total += data.count
                guard total <= byteLimit else { throw BackupError.invalid }
                studies[key] = try JSONDecoder().decode(StudyNotes.self, from: data)
            }
            let result = Self(library: library, studies: studies)
            try result.validate()
            return result
        }
    }

    func restore(at root: URL) throws {
        try validate()
        // Enforce aggregate limit even when called directly, without decoding an envelope.
        guard try Self.encoded(self).count <= Self.byteLimit else { throw BackupError.invalid }
        try StoreAccess.locked(root) {
            let libraryFile = root.appendingPathComponent("Patients.json")
            let original = try StoreAccess.read(libraryFile, limit: 16 * 1024 * 1024)
            var merged = try StudyLibrary.store(at: root).readUnlocked(default: StudyLibrary(), valid: { $0.valid })
            for patient in library.patients {
                if let index = merged.patients.firstIndex(where: { $0.id == patient.id }) {
                    guard merged.patients[index].name == patient.name else { throw BackupError.conflict(patient.name) }
                    for study in patient.studies {
                        if let existing = merged.patients[index].studies.first(where: {
                            $0.id == study.id || $0.link.fingerprint == study.link.fingerprint
                        }) {
                            guard existing.title == study.title, existing.date == study.date,
                                  existing.link.fingerprint == study.link.fingerprint,
                                  existing.link.dicomSeries == study.link.dicomSeries else {
                                throw BackupError.conflict(study.title)
                            }
                            // Keep the local security-scoped grant, which belongs to this Mac.
                        } else { merged.patients[index].studies.append(study) }
                    }
                } else { merged.patients.append(patient) }
            }
            guard merged.valid else { throw BackupError.invalid }
            var changes: [StoreAccess.Update] = []
            let newLibrary = try Self.encoded(merged)
            guard newLibrary.count <= 16 * 1024 * 1024 else { throw BackupError.invalid }
            if original != newLibrary { changes.append(.init(path: "Patients.json", before: original, after: newLibrary)) }
            for (key, notes) in studies.sorted(by: { $0.key < $1.key }) {
                let path = "Studies/" + key + ".json"
                let existing = try StoreAccess.read(root.appendingPathComponent(path), limit: 1_048_576)
                if let existing {
                    guard try JSONDecoder().decode(StudyNotes.self, from: existing) == notes else {
                        throw BackupError.conflict(String(localized: "Отметки исследования") + " " + String(key.prefix(8)))
                    }
                } else { changes.append(.init(path: path, before: nil, after: try Self.encoded(notes))) }
            }
            try StoreAccess.commitUnlocked(changes, at: root)
        }
    }
}

extension StudyNotes {
    // Backups may be restored before source volumes are available. Validate the
    // bounded document structure here; exact geometry is revalidated on opening.
    var portableValid: Bool {
        func point(_ p: SIMD3<Double>) -> Bool {
            (0..<3).allSatisfy { (-50...204800).contains(p[$0]) }
        }
        func arch(_ a: SavedArch?) -> Bool {
            guard let a else { return true }
            return (3...40).contains(a.nodes.count) && (0..<2048).contains(a.axial) &&
                a.nodes.allSatisfy { (0...204800).contains($0.x) && (0...204800).contains($0.y) } &&
                ArchCurve(nodes: a.nodes, resolution: 1) != nil
        }
        func view(_ v: SavedViewingState?) -> Bool {
            guard let v else { return true }
            guard v.display.valid else { return false }
            switch v.location {
            case let .slice(plane, index):
                guard Plane(rawValue: plane) != nil, (0..<2048).contains(index), v.ruler == nil else { return false }
            case .panorama(let p):
                guard (0...1).contains(p.jaw), arch(p.arch), (0..<1536).contains(p.section),
                      (0...20).contains(p.thickness), (-10...10).contains(p.offset),
                      (0...2).contains(p.widthIndex), (0...2).contains(p.intervalIndex) else { return false }
                if let ruler = v.ruler {
                    guard p.detailed, case let .section(a, b) = ruler,
                          [a.x, a.y, b.x, b.y].allSatisfy({ (0...1).contains($0) }) else { return false }
                }
            case let .mpr(pose, plane, main):
                guard Plane(rawValue: plane) != nil, Plane(rawValue: main) != nil, point(pose.point),
                      abs(simd_length(pose.quaternion) - 1) < 1e-8,
                      (0..<3).allSatisfy({ abs(pose.roll[$0]) <= Double.pi }) else { return false }
                if let ruler = v.ruler {
                    guard case let .mpr(a, b) = ruler, point(a), point(b) else { return false }
                }
            }
            return true
        }
        return version == 1 && bookmarks.count <= 100 && Set(bookmarks.map(\.id)).count == bookmarks.count &&
            bookmarks.allSatisfy { (1...80).contains($0.name.count) && $0.name.utf8.count <= 512 &&
                ($0.annotation.map(StudyBookmark.validAnnotation) ?? true) && view($0.viewingState) } &&
            arch(upper) && arch(lower) && arch(baseline?.upper) && arch(baseline?.lower) &&
            arch(automaticArches?.upper) && arch(automaticArches?.lower) && view(lastView) &&
            (lastBookmark.map { id in bookmarks.contains { $0.id == id } } ?? true) &&
            (migratedSources.map { $0.count <= 128 && $0.allSatisfy { StudyStore.validFingerprint($0.key) && StudyStore.validFingerprint($0.value) } } ?? true)
    }
}
