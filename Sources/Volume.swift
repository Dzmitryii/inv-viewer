import CoreGraphics
import CryptoKit
import Foundation

enum INVError: LocalizedError {
    case unsupported, damaged, tooLarge, block(Int)

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Поддерживаются несжатые контейнеры InVivo INVFile 2.0 с блоками JPEG 2000 и 16-битными данными без знака.")
        case .damaged: String(localized: "Файл .inv повреждён или имеет неизвестную структуру.")
        case .tooLarge: String(localized: "Размер файла или объёма превышает пределы просмотрщика.")
        case .block(let index): String(localized: "Не удалось прочитать блок JPEG 2000 №\(index + 1).")
        }
    }
}

private final class Header: NSObject, XMLParserDelegate {
    var root = [String: String]()
    var volume = [String: String]()
    var orientation = [Double]()
    var rawAppended = false
    private var path = [String]()
    private var seenOrientation = false
    private(set) var valid = true

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        path.append(name)
        guard path.count <= 64 else {
            valid = false
            parser.abortParsing()
            return
        }
        if path == ["INVFile"] {
            root = attributes
        } else if path == ["INVFile", "Volume"] {
            if !volume.isEmpty || attributes.isEmpty { valid = false }
            volume = attributes
        } else if path == ["INVFile", "AppendedData"] {
            rawAppended = attributes == ["encoding": "raw"]
        } else if path == ["INVFile", "CaseInfo", "ImageInfo", "ImageOrientationPatient"] {
            if seenOrientation { valid = false }
            seenOrientation = true
            orientation = Self.numbers(attributes["Value"])
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        path.removeLast()
    }

    static func numbers(_ text: String?) -> [Double] {
        let fields = (text ?? "").split { $0.isWhitespace || $0 == "\\" }
        let values = fields.compactMap { Double($0) }
        return values.count == fields.count && values.allSatisfy(\.isFinite) ? values : []
    }
}

enum Plane: Int, CaseIterable {
    case axial, coronal, sagittal

    func title(oriented: Bool) -> String {
        switch self {
        case .axial: oriented ? String(localized: "Аксиальная") : "XY"
        case .coronal: oriented ? String(localized: "Корональная") : "XZ"
        case .sagittal: oriented ? String(localized: "Сагиттальная") : "YZ"
        }
    }

    // Screen left, right, top, bottom in patient coordinates for the verified orientation.
    var labels: [String] {
        switch self {
        case .axial: ["R", "L", "A", "P"]
        case .coronal: ["R", "L", "S", "I"]
        case .sagittal: ["A", "P", "S", "I"]
        }
    }
}

struct Volume: Sendable {
    let width: Int
    let height: Int
    let depth: Int
    let spacing: [Double]
    let oriented: Bool
    let windowWidth: Double
    let windowCenter: Double
    let pixels: [UInt16]
    var peak: UInt16? = nil
    var fingerprint: String? = nil
    var legacyFingerprints: [String] = []
    var dicomSeries: String? = nil
    var dicomSeriesNumber: Int? = nil
    var invertedGrayscale = false

    func matchesFingerprint(_ value: String) -> Bool {
        fingerprint == value || legacyFingerprints.contains(value)
    }

    func analysisValue(_ value: UInt16) -> UInt16 {
        invertedGrayscale ? UInt16.max - value : value
    }

    private static let maxBlockSamples = 16_000_000

    static func read(_ url: URL, dicomSeries: String? = nil) throws -> Volume {
        try Task.checkCancellation()
        guard url.isFileURL else { throw INVError.unsupported }
        if StudyFile.isDirectory(url) { return try DICOM.readSeries(url, selected: dicomSeries) }
        let data = try StudyFile.read(url)
        var volume: Volume
        if StudyFile.dicomExtensions.contains(url.pathExtension.lowercased()) || DICOM.hasPreamble(data) {
            volume = try DICOM.decode(data)
            volume.legacyFingerprints = [DICOM.singleFileSeriesFingerprint(data)]
        } else {
            volume = try decode(data)
        }
        volume.fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return volume
    }

    static func decode(_ data: Data) throws -> Volume {
        guard data.count <= StudyFile.maxBytes else { throw INVError.tooLarge }
        let prefix = data.prefix(256 * 1024)
        guard let opening = prefix.range(of: Data("<AppendedData".utf8)),
              let close = prefix[opening.upperBound...].firstIndex(of: 62),
              let xml = String(data: prefix[...close], encoding: .utf8),
              !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY")
        else { throw INVError.unsupported }

        let header = Header()
        let parser = XMLParser(data: Data((xml + "</AppendedData></INVFile>").utf8))
        parser.delegate = header
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), header.valid else { throw INVError.damaged }
        let attributes = header.volume
        guard header.rawAppended, header.root["version"] == "2.0", header.root["byteOrder"] == "LittleEndian",
              attributes["ScalarType"] == "UInt16", attributes["NumComp"] == "1",
              attributes["Offset"] == "0", attributes["Source"] == "Appended"
        else { throw INVError.unsupported }
        let dimensions = Header.numbers(attributes["Dimensions"])
        guard dimensions.count == 3, dimensions.allSatisfy({ (1...2048).contains($0) && $0.rounded() == $0 })
        else { throw INVError.tooLarge }
        let width = Int(dimensions[0]), height = Int(dimensions[1]), depth = Int(dimensions[2])
        let samples = width * height * depth
        guard samples <= StudyFile.maxSamples else { throw INVError.tooLarge }
        let spacing = Header.numbers(attributes["Spacing"])
        guard spacing.count == 3, spacing.allSatisfy({ (0.001...100).contains($0) })
        else { throw INVError.damaged }
        let coordinateSystem = Header.numbers(attributes["CoordinateSystem"])
        let oriented = header.orientation == [1, 0, 0, 0, 1, 0] &&
            coordinateSystem.count == 7 && Array(coordinateSystem.prefix(4)) == [0, 0, 0, 1]
        let window = Header.numbers(attributes["WindowLevel"])
        let validWindow = window.count == 2 && (1...65535).contains(window[0]) && (0...65535).contains(window[1])

        let pixels = try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            try unpack(bytes, start: close + 1, width: width, height: height, depth: depth)
        }
        let maximum = Double(pixels.max() ?? 0)
        return Volume(width: width, height: height, depth: depth, spacing: spacing, oriented: oriented,
                      windowWidth: validWindow ? window[0] : max(1, maximum),
                      windowCenter: validWindow ? window[1] : maximum / 2, pixels: pixels, peak: UInt16(maximum))
    }

    private static func unpack(_ bytes: UnsafeRawBufferPointer, start: Int,
                               width: Int, height: Int, depth: Int) throws -> [UInt16] {
        func little(_ index: Int) -> Int {
            Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
        }
        guard bytes.count - start >= 16, little(start) == 0x5f202020 else { throw INVError.damaged }
        let blocks = little(start + 4), per = little(start + 8), last = little(start + 12)
        guard (1...depth).contains(blocks), (1...64).contains(per), (1...per).contains(last),
              (blocks - 1) * per + last == depth, bytes.count - start >= 16 + 4 * blocks,
              width * height * (blocks == 1 ? last : per) <= maxBlockSamples
        else { throw INVError.damaged }
        var offset = start + 16 + 4 * blocks
        var ranges = [Range<Int>]()
        for block in 0..<blocks {
            let length = little(start + 16 + 4 * block)
            let frames = block == blocks - 1 ? last : per
            guard length >= 44 + 3 * frames, length <= bytes.count - offset,
                  validSIZ(bytes, at: offset, length: length, width: width, height: height, frames: frames)
            else { throw INVError.block(block) }
            ranges.append(offset..<(offset + length))
            offset += length
        }
        guard bytes.count - offset <= 256,
              String(decoding: bytes[offset...], as: UTF8.self)
                .filter({ !$0.isWhitespace }) == "</AppendedData></INVFile>"
        else { throw INVError.damaged }

        var pixels = [UInt16](repeating: 0, count: width * height * depth)
        try pixels.withUnsafeMutableBufferPointer { output in
            for (block, range) in ranges.enumerated() {
                try Task.checkCancellation()
                let input = bytes.baseAddress!.advanced(by: range.lowerBound).assumingMemoryBound(to: UInt8.self)
                let target = output.baseAddress!.advanced(by: block * per * width * height)
                let frames = block == blocks - 1 ? last : per
                guard inv_decode_j2k(input, range.count, UInt32(width), UInt32(height), UInt32(frames), target) == 1
                else { throw INVError.block(block) }
            }
        }
        return pixels
    }

    // Bound the JPEG 2000 grid before passing it to the native decoder.
    private static func validSIZ(_ bytes: UnsafeRawBufferPointer, at offset: Int, length: Int,
                                 width: Int, height: Int, frames: Int) -> Bool {
        func be32(_ index: Int) -> Int {
            Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + index, as: UInt32.self)))
        }
        func be16(_ index: Int) -> Int {
            Int(UInt16(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + index, as: UInt16.self)))
        }
        guard be32(0) == 0xff4fff51, be16(4) == 38 + 3 * frames, be16(40) == frames,
              be32(8) == width, be32(12) == height, be32(16) == 0, be32(20) == 0,
              be32(32) == 0, be32(36) == 0, be16(length - 2) == 0xffd9
        else { return false }
        let tileWidth = be32(24), tileHeight = be32(28)
        guard (1...8192).contains(tileWidth), (1...8192).contains(tileHeight),
              ((width + tileWidth - 1) / tileWidth) * ((height + tileHeight - 1) / tileHeight) <= 16
        else { return false }
        return (0..<frames).allSatisfy { frame in
            let component = offset + 42 + 3 * frame
            return bytes[component] == 15 && bytes[component + 1] == 1 && bytes[component + 2] == 1
        }
    }

    func sliceCount(_ plane: Plane) -> Int {
        switch plane {
        case .axial: depth
        case .coronal: height
        case .sagittal: width
        }
    }

    func sliceSize(_ plane: Plane) -> (width: Int, height: Int, aspect: Double) {
        switch plane {
        case .axial: (width, height, Double(width) * spacing[0] / (Double(height) * spacing[1]))
        case .coronal: (width, depth, Double(width) * spacing[0] / (Double(depth) * spacing[2]))
        case .sagittal: (height, depth, Double(height) * spacing[1] / (Double(depth) * spacing[2]))
        }
    }

    func image(_ plane: Plane, index: Int, windowWidth: Double, center: Double) -> CGImage? {
        let size = sliceSize(plane)
        let window = GrayWindow(width: windowWidth, center: center)
        var bytes = Data(count: size.width * size.height)
        bytes.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
            for row in 0..<size.height {
                let start: Int
                let step: Int
                switch plane {
                case .axial:
                    start = (index * height + row) * width
                    step = 1
                case .coronal:
                    start = ((depth - 1 - row) * height + index) * width
                    step = 1
                case .sagittal:
                    start = (depth - 1 - row) * height * width + index
                    step = width
                }
                for column in 0..<size.width {
                    output[row * size.width + column] = window.byte(Double(pixels[start + column * step]))
                }
            }
        }
        return GrayWindow.image(bytes, columns: size.width, rows: size.height)
    }
}
