import Foundation

struct ScanLink: Codable, Equatable, Sendable {
    let bookmark: Data
    let fileName: String
    let fingerprint: String
    var dicomSeries: String? = nil
    var seriesNumber: Int? = nil

    var displayName: String {
        if let seriesNumber { return String(localized: "\(fileName) · Серия \(seriesNumber)") }
        return fileName
    }

    static func make(_ url: URL, fingerprint: String, dicomSeries: String? = nil, seriesNumber: Int? = nil) throws -> ScanLink {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        let link = ScanLink(bookmark: bookmark, fileName: url.lastPathComponent, fingerprint: fingerprint,
                            dicomSeries: dicomSeries, seriesNumber: seriesNumber)
        guard link.valid else { throw StudyLibraryError.invalid }
        return link
    }

    func resolve() throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark,
                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard StudyFile.accepts(url) else { throw StudyLibraryError.invalid }
        // The caller still checks the content hash before displaying a resolved file.
        return url
    }

    var valid: Bool {
        (1...65536).contains(bookmark.count) && (1...1024).contains(fileName.utf8.count) &&
            (dicomSeries == nil || DICOM.uid(dicomSeries) != nil) && fingerprint.utf8.count == 64 && fingerprint.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}

struct PatientStudy: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var date: Date
    var link: ScanLink

    var valid: Bool {
        StudyLibrary.validName(title) && date.timeIntervalSince1970.isFinite && link.valid
    }
}

struct LibraryPatient: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var studies: [PatientStudy] = []

    var valid: Bool {
        StudyLibrary.validName(name) && Set(studies.map(\.id)).count == studies.count &&
            Set(studies.map { $0.link.fingerprint }).count == studies.count && studies.allSatisfy(\.valid)
    }
}

enum StudyLibraryError: LocalizedError {
    case invalid, differentScan, duplicate

    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "Данные библиотеки имеют неподдерживаемый формат.")
        case .differentScan: String(localized: "Это другой файл. Для восстановления связи выберите точную копию исходного снимка.")
        case .duplicate: String(localized: "Этот снимок уже есть в карточке пациента.")
        }
    }
}

struct StudyLibrary: Codable, Equatable {
    var version = 1
    var patients: [LibraryPatient] = []

    static var storageRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("INV Viewer", isDirectory: true)
    }

    static func store(at root: URL) -> LocalDocument<Self> {
        LocalDocument(file: root.appendingPathComponent("Patients.json"), limit: 16 * 1024 * 1024)
    }

    static func validName(_ name: String) -> Bool {
        (1...120).contains(name.count) && name.utf8.count <= 800 &&
            name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
            name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    var valid: Bool {
        version == 1 && Set(patients.map(\.id)).count == patients.count && patients.allSatisfy(\.valid)
    }
}

struct RecentScans: Codable, Equatable {
    var version = 1
    var links: [ScanLink] = []

    static func store(at root: URL) -> LocalDocument<Self> {
        LocalDocument(file: root.appendingPathComponent("Recent.json"), limit: 2 * 1024 * 1024)
    }

    mutating func record(_ link: ScanLink) {
        links.removeAll { $0.fingerprint == link.fingerprint }
        links.insert(link, at: 0)
        links = Array(links.prefix(12))
    }

    var valid: Bool {
        version == 1 && links.count <= 12 &&
            Set(links.map(\.fingerprint)).count == links.count && links.allSatisfy(\.valid)
    }
}
