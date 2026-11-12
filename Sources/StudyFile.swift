import Foundation
import Darwin
import UniformTypeIdentifiers

enum StudyFile {
    static let dicomExtensions = ["dcm", "dicom", "ima"]
    static let maxBytes = 256 * 1024 * 1024
    static let maxSamples = 160_000_000

    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && (isDirectory(url) || url.pathExtension.lowercased() == "inv" ||
                          dicomExtensions.contains(url.pathExtension.lowercased()))
    }

    static func isDirectory(_ url: URL) -> Bool {
        if url.hasDirectoryPath { return true }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static var contentTypes: [UTType] {
        [UTType(importedAs: "local.cbct.invivo-file", conformingTo: .data),
         UTType(importedAs: "local.cbct.dicom-file", conformingTo: .data)]
        + dicomExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    static func inspectDICOM<T>(_ url: URL, inspect: (Data) throws -> T?) throws -> T? {
        try withRegularFile(url, candidateOnly: true) { file, size in
            var data = try file.read(upToCount: 132) ?? Data()
            guard DICOM.hasPreamble(data) else { return nil }
            var target = min(65_536, size)
            while true {
                try Task.checkCancellation()
                guard target <= maxBytes else { throw INVError.tooLarge }
                let chunk = try file.read(upToCount: max(0, target - data.count)) ?? Data()
                data.append(chunk)
                do { return try inspect(data) }
                catch DICOMError.damaged where data.count == target && target < size {
                    target = min(size, target * 2)
                }
            }
        }
    }

    static func read(_ url: URL) throws -> Data {
        guard let data = try withRegularFile(url, candidateOnly: false, read: readFile) else { throw INVError.damaged }
        return data
    }

    static func readDICOMMember(_ url: URL) throws -> Data {
        guard let data = try withRegularFile(url, candidateOnly: true, read: readFile) else { throw DICOMError.damaged }
        return data
    }

    private static func readFile(_ file: FileHandle, size: Int) throws -> Data? {
        guard size <= maxBytes else { throw INVError.tooLarge }
        var data = Data()
        while data.count < size + 1 {
            try Task.checkCancellation()
            let chunk = try file.read(upToCount: min(1_048_576, size + 1 - data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count == size else { throw INVError.damaged }
        return data
    }

    private static func withRegularFile<T>(_ url: URL, candidateOnly: Bool,
                                        read: (FileHandle, Int) throws -> T?) throws -> T? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | (candidateOnly ? O_NOFOLLOW : 0))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            if candidateOnly { return nil }
            throw INVError.unsupported
        }
        return try read(file, Int(info.st_size))
    }
}
