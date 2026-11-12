import Foundation

enum BackupFixture {
    private static func check(_ condition: Bool, _ message: String = "Backup regression") { precondition(condition, message) }

    static func verify(in root: URL, volume: Volume) throws {
        let source = root.appendingPathComponent("backup-source", isDirectory: true)
        let target = root.appendingPathComponent("backup-target", isDirectory: true)
        let key = volume.fingerprint!
        let link = ScanLink(bookmark: Data([1]), fileName: "synthetic.inv", fingerprint: key)
        let patient = LibraryPatient(name: "Synthetic patient", studies: [PatientStudy(title: "Synthetic scan", date: Date(timeIntervalSince1970: 0), link: link)])
        var library = StudyLibrary()
        library.patients = [patient]
        var notes = StudyNotes()
        notes.upper = SyntheticStudy.defaultArches(for: volume).upper
        notes.bookmarks = [StudyBookmark(name: "Backup marker", display: SavedDisplay(width: 4000, level: 2000, zoom: 1), location: .slice(plane: 0, index: 2))]
        try StudyLibrary.store(at: source).write(library, replacing: StudyLibrary(), default: StudyLibrary(), valid: { $0.valid })
        try StudyStore(root: source.appendingPathComponent("Studies"), fingerprint: key)!.write(notes, replacing: StudyNotes(), volume: volume)
        let exported = try LibraryBackup.snapshot(at: source)
        let encoded = try exported.data()
        let archive = try LibraryBackup.decode(encoded)
        try archive.restore(at: target)
        try archive.restore(at: target)
        check(try LibraryBackup.snapshot(at: target) == archive, "Repeated import changed data")

        let before = try LibraryBackup.snapshot(at: target).data()
        var conflict = archive
        conflict.library.patients[0].name = "Different name"
        do { try conflict.restore(at: target); fatalError("Conflicting patient overwritten") }
        catch BackupError.conflict {}
        conflict = archive
        conflict.studies[key]?.bookmarks[0].name = "Different note"
        do { try conflict.restore(at: target); fatalError("Conflicting notes overwritten") }
        catch BackupError.conflict {}
        check(try LibraryBackup.snapshot(at: target).data() == before)
        var invalid = archive
        invalid.studies["../escape"] = notes
        do { try invalid.restore(at: target); fatalError("Traversal key accepted") }
        catch BackupError.invalid {}
        invalid = archive
        invalid.version = 99
        do { try invalid.restore(at: target); fatalError("Future schema accepted") }
        catch BackupError.invalid {}
        var tampered = String(decoding: encoded, as: UTF8.self)
        tampered = tampered.replacingOccurrences(of: "Backup marker", with: "Changed marker")
        do { _ = try LibraryBackup.decode(Data(tampered.utf8)); fatalError("Checksum ignored") }
        catch BackupError.invalid {}

        // A prepared transaction interrupted after its first file must complete
        // before an ordinary LocalDocument read returns any state.
        let recovery = root.appendingPathComponent("backup-recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let patientData = try JSONEncoder().encode(library)
        let noteData = try JSONEncoder().encode(notes)
        let updates = [StoreAccess.Update(path: "Patients.json", before: nil, after: patientData),
                       StoreAccess.Update(path: "Studies/" + key + ".json", before: nil, after: noteData)]
        let journal = try JSONEncoder().encode(StoreAccess.Journal(version: 1, updates: updates))
        try StoreAccess.atomicWrite(journal, to: recovery.appendingPathComponent(".PendingImport.json"))
        try StoreAccess.atomicWrite(patientData, to: recovery.appendingPathComponent("Patients.json"))
        check(try StudyLibrary.store(at: recovery).read(default: StudyLibrary(), valid: { $0.valid }) == library)
        check(try StudyStore(root: recovery.appendingPathComponent("Studies"), fingerprint: key)!.read(volume: volume) == notes)
        check(!FileManager.default.fileExists(atPath: recovery.appendingPathComponent(".PendingImport.json").path))

        let changed = root.appendingPathComponent("backup-recovery-conflict", isDirectory: true)
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        let concurrent = try JSONEncoder().encode(StudyLibrary())
        try StoreAccess.atomicWrite(journal, to: changed.appendingPathComponent(".PendingImport.json"))
        try StoreAccess.atomicWrite(concurrent, to: changed.appendingPathComponent("Patients.json"))
        do { _ = try StudyLibrary.store(at: changed).read(default: StudyLibrary(), valid: { $0.valid }); fatalError("Recovery overwrote concurrent data") }
        catch StudyStoreError.changed {}
        check(try Data(contentsOf: changed.appendingPathComponent("Patients.json")) == concurrent)
        print("PASS · portable backup round trip, repeat import, conflict/checksum/path/schema rejection and interrupted transaction recovery")
    }
}
