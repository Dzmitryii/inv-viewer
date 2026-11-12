import Foundation
import CryptoKit
import simd

enum DICOMError: LocalizedError {
    case unsupported, transferSyntax, damaged, geometry, emptyFolder, missingSeries

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Поддерживаются DICOM КТ с несжатыми монохромными данными.")
        case .transferSyntax: String(localized: "Этот способ кодирования DICOM не поддерживается. Экспортируйте серию как несжатый Little Endian DICOM.")
        case .damaged: String(localized: "Файл DICOM повреждён или не содержит полный объём пикселей.")
        case .geometry: String(localized: "Геометрия DICOM неполная, наклонная или неравномерная. Объём не открыт, чтобы сохранить корректный масштаб и стороны.")
        case .emptyFolder: String(localized: "В этой папке нет подходящей серии DICOM.")
        case .missingSeries: String(localized: "Сохранённая серия DICOM не найдена в выбранной папке.")
        }
    }
}

private enum Tag {
    static let syntax: UInt32 = 0x00020010
    static let sopClass: UInt32 = 0x00080016
    static let series: UInt32 = 0x0020000e
    static let seriesNumber: UInt32 = 0x00200011
    static let reference: UInt32 = 0x00200052
    static let anatomy: UInt32 = 0x00102210
    static let position: UInt32 = 0x00200032
    static let orientation: UInt32 = 0x00200037
    static let samples: UInt32 = 0x00280002
    static let photometric: UInt32 = 0x00280004
    static let frames: UInt32 = 0x00280008
    static let rows: UInt32 = 0x00280010
    static let columns: UInt32 = 0x00280011
    static let spacing: UInt32 = 0x00280030
    static let thickness: UInt32 = 0x00180050
    static let sliceSpacing: UInt32 = 0x00180088
    static let bits: UInt32 = 0x00280100
    static let stored: UInt32 = 0x00280101
    static let high: UInt32 = 0x00280102
    static let signed: UInt32 = 0x00280103
    static let center: UInt32 = 0x00281050
    static let width: UInt32 = 0x00281051
    static let intercept: UInt32 = 0x00281052
    static let slope: UInt32 = 0x00281053
    static let voiFunction: UInt32 = 0x00281056
    static let shared: UInt32 = 0x52009229
    static let perFrame: UInt32 = 0x52009230
    static let planePosition: UInt32 = 0x00209113
    static let planeOrientation: UInt32 = 0x00209116
    static let pixelMeasures: UInt32 = 0x00289110
    static let pixelTransform: UInt32 = 0x00289145
    static let frameVOI: UInt32 = 0x00289132
    static let pixels: UInt32 = 0x7fe00010
    static let item: UInt32 = 0xfffee000
    static let itemEnd: UInt32 = 0xfffee00d
    static let sequenceEnd: UInt32 = 0xfffee0dd

    static let values: Set<UInt32> = [syntax, sopClass, series, seriesNumber, reference, anatomy, position, orientation,
        samples, photometric, frames, rows, columns, spacing, thickness, sliceSpacing, bits, stored, high, signed,
        center, width, intercept, slope, voiFunction, pixels]
    static let sequences: Set<UInt32> = [shared, perFrame, planePosition, planeOrientation,
        pixelMeasures, pixelTransform, frameVOI]
}

private struct DICOMDataset {
    var values: [UInt32: Range<Int>] = [:]
    var sequences: [UInt32: [DICOMDataset]] = [:]
}

// Only geometry and grayscale elements are retained. Unknown attributes and
// sequences are traversed only as needed to find the next top-level element.
private struct DICOMParser {
    let bytes: UnsafeRawBufferPointer
    private var cursor = 132
    private var explicit = true
    private(set) var nativePixels = true
    private var budget = 500_000
    private static let shortVRs: Set<UInt16> = Set([
        "AE", "AS", "AT", "CS", "DA", "DS", "DT", "FD", "FL", "IS", "LO", "LT",
        "PN", "SH", "SL", "SS", "ST", "TM", "UI", "UL", "US"
    ].map { vr in UInt16(vr.utf8.first!) | UInt16(vr.utf8.last!) << 8 })

    init(_ bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

    mutating func read(probe: Bool = false) throws -> DICOMDataset {
        var syntax: String?
        while cursor <= bytes.count - 8, word(cursor) == 2 {
            let element = try header(limit: bytes.count)
            guard let end = element.end else { throw DICOMError.damaged }
            if element.tag == Tag.syntax {
                guard syntax == nil, end - cursor <= 64 else { throw DICOMError.damaged }
                syntax = String(decoding: bytes[cursor..<end], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0} "))
            }
            cursor = end
        }
        switch syntax {
        case "1.2.840.10008.1.2.1": explicit = true
        case "1.2.840.10008.1.2": explicit = false
        case nil: throw DICOMError.damaged
        case let value? where probe && (value.hasPrefix("1.2.840.10008.1.2.4.") || value == "1.2.840.10008.1.2.5"):
            nativePixels = false
            explicit = true
        default: throw DICOMError.transferSyntax
        }
        return try dataset(limit: bytes.count, depth: 0, retain: true, undefined: false, probe: probe)
    }

    private func word(_ offset: Int) -> UInt16 {
        UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    private func long(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    private mutating func header(limit: Int) throws -> (tag: UInt32, end: Int?, sequence: Bool) {
        guard cursor <= limit - 8, budget > 0 else { throw DICOMError.damaged }
        budget -= 1
        let group = word(cursor)
        let tag = UInt32(group) << 16 | UInt32(word(cursor + 2))
        var length: UInt32
        var sequence = false
        if explicit && group != 0xfffe {
            let vr = word(cursor + 4)
            let first = bytes[cursor + 4], second = bytes[cursor + 5]
            guard (65...90).contains(first), (65...90).contains(second) else { throw DICOMError.damaged }
            // DICOM PS3.5 defines these VRs with a two-byte value length.
            if Self.shortVRs.contains(vr) {
                length = UInt32(word(cursor + 6))
                cursor += 8
            } else {
                guard cursor <= limit - 12, word(cursor + 6) == 0 else { throw DICOMError.damaged }
                sequence = vr == 0x5153 // SQ
                length = long(cursor + 8)
                cursor += 12
            }
        } else {
            sequence = Tag.sequences.contains(tag)
            length = long(cursor + 4)
            cursor += 8
        }
        if length == UInt32.max { return (tag, nil, sequence) }
        guard length % 2 == 0, Int(length) <= limit - cursor else { throw DICOMError.damaged }
        return (tag, cursor + Int(length), sequence)
    }

    private mutating func dataset(limit: Int, depth: Int, retain: Bool, undefined: Bool,
                                  probe: Bool = false) throws -> DICOMDataset {
        guard depth <= 12 else { throw DICOMError.damaged }
        var result = DICOMDataset()
        while cursor < limit {
            if probe, cursor <= limit - 8, word(cursor) == 0x7fe0, word(cursor + 2) == 0x0010 {
                return result
            }
            let element = try header(limit: limit)
            if element.tag == Tag.itemEnd {
                guard undefined, element.end == cursor else { throw DICOMError.damaged }
                return result
            }
            guard element.tag >> 16 != 0xfffe else { throw DICOMError.damaged }
            if element.tag == Tag.pixels, element.end == nil { throw DICOMError.transferSyntax }
            let wantedSequence = retain && !probe && Tag.sequences.contains(element.tag)
            if wantedSequence || element.end == nil {
                guard element.sequence || element.end == nil else { throw DICOMError.damaged }
                let items = try sequence(end: element.end, limit: limit, depth: depth + 1, retain: wantedSequence)
                if wantedSequence {
                    guard result.sequences.updateValue(items, forKey: element.tag) == nil else { throw DICOMError.damaged }
                }
                continue
            }
            guard let end = element.end else { throw DICOMError.damaged }
            if retain && Tag.values.contains(element.tag) {
                guard element.tag == Tag.pixels || end - cursor <= 1024,
                      result.values.updateValue(cursor..<end, forKey: element.tag) == nil else { throw DICOMError.damaged }
            }
            cursor = end
            if probe, let range = result.values[Tag.sopClass] {
                let sop = String(decoding: bytes[range], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0} "))
                if !DICOM.supportedClasses.contains(sop) { return result }
                if result.values[Tag.series] != nil, result.values[Tag.rows] != nil, result.values[Tag.columns] != nil,
                   sop == DICOM.classicCT || result.values[Tag.frames] != nil { return result }
            }
        }
        guard cursor == limit, !undefined else { throw DICOMError.damaged }
        return result
    }

    private mutating func sequence(end: Int?, limit: Int, depth: Int, retain: Bool) throws -> [DICOMDataset] {
        let boundary = end ?? limit
        var items: [DICOMDataset] = []
        while cursor < boundary {
            let element = try header(limit: boundary)
            if element.tag == Tag.sequenceEnd {
                guard end == nil, element.end == cursor else { throw DICOMError.damaged }
                return items
            }
            guard element.tag == Tag.item, !retain || items.count < 2048 else { throw DICOMError.damaged }
            if !retain, let stop = element.end {
                cursor = stop
            } else {
                let item = try dataset(limit: element.end ?? boundary, depth: depth, retain: retain, undefined: element.end == nil)
                if retain { items.append(item) }
            }
        }
        guard cursor == boundary, end != nil else { throw DICOMError.damaged }
        return items
    }
}

private struct DICOMAxis: Equatable {
    let index: Int
    let forward: Bool

    init(_ direction: SIMD3<Double>) throws {
        guard let index = (0..<3).first(where: { abs(abs(direction[$0]) - 1) <= 0.000001 }),
              (0..<3).allSatisfy({ $0 == index || abs(direction[$0]) <= 0.000001 }) else {
            throw DICOMError.geometry
        }
        self.index = index
        self.forward = direction[index] > 0
    }
}

private struct DICOMFrame {
    let position: SIMD3<Double>
    let x: DICOMAxis
    let y: DICOMAxis
    let spacing: SIMD2<Double>
    let sliceSpacing: Double?
    let slope: Double
    let intercept: Double
    let center: Double?
    let width: Double?
    let linearExact: Bool
}

private struct DICOMImage {
    let data: Data
    let pixelRange: Range<Int>
    let columns: Int
    let rows: Int
    let bits: Int
    let stored: Int
    let signed: Bool
    let inverted: Bool
    let series: String?
    let reference: String?
    let frames: [DICOMFrame]

    init(_ data: Data) throws {
        guard DICOM.hasPreamble(data) else { throw DICOMError.damaged }
        let dataset = try data.withUnsafeBytes { bytes in
            var parser = DICOMParser(bytes)
            return try parser.read()
        }

        func string(_ field: Range<Int>?) -> String? {
            guard let field else { return nil }
            return String(decoding: data[field], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}")))
        }
        func us(_ tag: UInt32) -> Int? {
            guard let range = dataset.values[tag], range.count == 2 else { return nil }
            return Int(data[range.lowerBound]) | Int(data[range.lowerBound + 1]) << 8
        }

        let sopClass = string(dataset.values[Tag.sopClass]) ?? ""
        let photo = string(dataset.values[Tag.photometric])
        guard DICOM.supportedClasses.contains(sopClass),
              [nil, "BIPED"].contains(string(dataset.values[Tag.anatomy])),
              us(Tag.samples) == 1, photo == "MONOCHROME1" || photo == "MONOCHROME2",
              let bits = us(Tag.bits), bits == 8 || bits == 16,
              let stored = us(Tag.stored), (1...bits).contains(stored), us(Tag.high) == stored - 1,
              let representation = us(Tag.signed), representation == 0 || representation == 1,
              let rows = us(Tag.rows), (1...2048).contains(rows),
              let columns = us(Tag.columns), (1...2048).contains(columns) else { throw DICOMError.unsupported }
        let countText = string(dataset.values[Tag.frames])
        let count = countText == nil ? 1 : Int(countText ?? "") ?? 0
        guard (1...2048).contains(count), rows * columns * count <= StudyFile.maxSamples else { throw INVError.tooLarge }
        let pixelBytes = rows * columns * count * (bits / 8)
        guard let pixelRange = dataset.values[Tag.pixels], pixelRange.count == pixelBytes + (pixelBytes % 2),
              pixelBytes % 2 == 0 || data[pixelRange.upperBound - 1] == 0 else { throw DICOMError.damaged }
        let shared = dataset.sequences[Tag.shared] ?? []
        let individual = dataset.sequences[Tag.perFrame] ?? []
        guard shared.count <= 1, individual.count == count || (count == 1 && individual.isEmpty) else {
            throw DICOMError.geometry
        }

        var frames: [DICOMFrame] = []
        for index in 0..<count {
            let frame = individual.isEmpty ? nil : individual[index]
            func field(_ value: UInt32, in group: UInt32, allowTop: Bool = true) throws -> String? {
                let local = frame?.sequences[group]
                let common = shared.first?.sequences[group]
                guard (local?.count ?? 1) == 1, (common?.count ?? 1) == 1,
                      local == nil || common == nil else { throw DICOMError.geometry }
                return string(local?.first?.values[value] ?? common?.first?.values[value]
                    ?? (allowTop ? dataset.values[value] : nil))
            }
            func numbers(_ text: String?, count: Int) throws -> [Double] {
                let parts = text?.split(separator: "\\", omittingEmptySubsequences: false) ?? []
                let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == count, values.count == count, values.allSatisfy(\.isFinite) else {
                    throw DICOMError.geometry
                }
                return values
            }
            func scalar(_ value: UInt32, in group: UInt32) throws -> Double? {
                guard let text = try field(value, in: group) else { return nil }
                guard let first = text.split(separator: "\\", omittingEmptySubsequences: false).first,
                      let result = Double(first.trimmingCharacters(in: .whitespaces)), result.isFinite else {
                    throw DICOMError.geometry
                }
                return result
            }
            let p = try numbers(field(Tag.position, in: Tag.planePosition, allowTop: count == 1), count: 3)
            let orientation = try numbers(field(Tag.orientation, in: Tag.planeOrientation), count: 6)
            let x = try DICOMAxis(SIMD3(orientation[0], orientation[1], orientation[2]))
            let y = try DICOMAxis(SIMD3(orientation[3], orientation[4], orientation[5]))
            let spacing = try numbers(field(Tag.spacing, in: Tag.pixelMeasures), count: 2)
            let dz = try scalar(Tag.sliceSpacing, in: Tag.pixelMeasures) ?? scalar(Tag.thickness, in: Tag.pixelMeasures)
            let slope = try scalar(Tag.slope, in: Tag.pixelTransform) ?? 1
            let intercept = try scalar(Tag.intercept, in: Tag.pixelTransform) ?? 0
            guard x.index != y.index, spacing.allSatisfy({ (0.001...100).contains($0) }),
                  (0.000001...1_000_000).contains(slope) else { throw DICOMError.geometry }
            let voi = try field(Tag.voiFunction, in: Tag.frameVOI)
            let linear = voi == nil || voi == "LINEAR" || voi == "LINEAR_EXACT"
            let center = linear ? try scalar(Tag.center, in: Tag.frameVOI) : nil
            let width = linear ? try scalar(Tag.width, in: Tag.frameVOI) : nil
            frames.append(DICOMFrame(position: SIMD3(p[0], p[1], p[2]), x: x, y: y,
                                    spacing: SIMD2(spacing[1], spacing[0]), sliceSpacing: dz, slope: slope,
                                    intercept: intercept, center: center, width: width, linearExact: voi == "LINEAR_EXACT"))
        }
        self.data = data
        self.pixelRange = pixelRange
        self.columns = columns
        self.rows = rows
        self.bits = bits
        self.stored = stored
        self.signed = representation == 1
        self.inverted = photo == "MONOCHROME1"
        self.series = DICOM.uid(string(dataset.values[Tag.series]))
        self.reference = DICOM.uid(string(dataset.values[Tag.reference]))
        self.frames = frames
    }
}

struct DICOMSeriesOption: Sendable, Equatable {
    let id: String
    let number: Int?
    let width: Int
    let height: Int
    let slices: Int
}

struct DICOMSeriesChoice: LocalizedError {
    let options: [DICOMSeriesOption]

    var errorDescription: String? { String(localized: "В папке несколько серий КТ. Выберите нужную серию.") }
}

enum DICOM {
    static func singleFileSeriesFingerprint(_ data: Data) -> String {
        var hash = SHA256()
        hash.update(data: Data("DICOM-series-v1".utf8))
        hash.update(data: Data(SHA256.hash(data: data)))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    fileprivate static let classicCT = "1.2.840.10008.5.1.4.1.1.2"
    fileprivate static let supportedClasses: Set<String> = [
        classicCT, "1.2.840.10008.5.1.4.1.1.2.1", "1.2.840.10008.5.1.4.1.1.2.2",
        "1.2.840.10008.5.1.4.1.1.13.1.2", "1.2.840.10008.5.1.4.1.1.7.3"
    ]

    static func uid(_ value: String?) -> String? {
        guard let value, (1...64).contains(value.utf8.count),
              !value.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty),
              value.utf8.allSatisfy({ $0 == 46 || (48...57).contains($0) }) else { return nil }
        return value
    }

    static func hasPreamble(_ data: Data) -> Bool {
        data.count >= 132 && data[128..<132].elementsEqual([68, 73, 67, 77])
    }

    static func decode(_ data: Data) throws -> Volume { try assemble([DICOMImage(data)]) }

    private struct Candidate {
        let id: String
        let number: Int?
        let width: Int
        let height: Int
        let slices: Int
        let nativePixels: Bool

        static func probe(_ data: Data) throws -> Self? {
            try data.withUnsafeBytes { bytes in
                var parser = DICOMParser(bytes)
                let info = try parser.read(probe: true)
                func text(_ tag: UInt32) -> String? {
                    info.values[tag].map {
                        String(decoding: bytes[$0], as: UTF8.self)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0} "))
                    }
                }
                func us(_ tag: UInt32) -> Int? {
                    guard let range = info.values[tag], range.count == 2 else { return nil }
                    return Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: range.lowerBound, as: UInt16.self)))
                }
                guard let sop = text(Tag.sopClass) else { throw DICOMError.damaged }
                guard supportedClasses.contains(sop) else { return nil }
                guard let id = uid(text(Tag.series)), let width = us(Tag.columns), let height = us(Tag.rows) else {
                    throw DICOMError.damaged
                }
                let slices = text(Tag.frames).map { Int($0) ?? 0 } ?? 1
                guard (1...2048).contains(width), (1...2048).contains(height), (1...2048).contains(slices) else {
                    throw INVError.tooLarge
                }
                return Self(id: id, number: text(Tag.seriesNumber).flatMap(Int.init), width: width, height: height,
                            slices: slices, nativePixels: parser.nativePixels)
            }
        }
    }

    private struct Group {
        let first: Candidate
        var files: [URL] = []
        var slices = 0
        var nativePixels = true

        mutating func add(_ file: URL, _ candidate: Candidate) {
            files.append(file)
            slices += candidate.slices
            nativePixels = nativePixels && candidate.nativePixels
        }

        var option: DICOMSeriesOption {
            DICOMSeriesOption(id: first.id, number: first.number, width: first.width, height: first.height, slices: slices)
        }
    }

    private static func discover(_ directory: URL) throws -> [String: Group] {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey]
        var traversalError: Error?
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                    traversalError = error
                    return false
                }) else { throw DICOMError.emptyFolder }
        var groups: [String: Group] = [:]
        var count = 0
        var opaqueDICOM = false
        for case let file as URL in iterator {
            if Task.isCancelled { throw CancellationError() }
            count += 1
            guard count <= 32_768 else { throw INVError.tooLarge }
            if iterator.level > 12 { throw INVError.tooLarge }
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            let ext = file.pathExtension.lowercased()
            guard values.isRegularFile == true, ext.isEmpty || StudyFile.dicomExtensions.contains(ext),
                  file.lastPathComponent.uppercased() != "DICOMDIR" else { continue }
            let candidate: Candidate?
            do { candidate = try StudyFile.inspectDICOM(file, inspect: Candidate.probe) }
            catch DICOMError.transferSyntax { opaqueDICOM = true; continue }
            // Refuse an unreadable candidate rather than silently losing one or more CT slices.
            guard let candidate else { continue }
            guard groups.count < 128 || groups[candidate.id] != nil else { throw INVError.tooLarge }
            groups[candidate.id, default: Group(first: candidate)].add(file, candidate)
        }
        if let traversalError { throw traversalError }
        // An opaque transfer syntax may belong to one of the same series.
        if opaqueDICOM { throw DICOMError.transferSyntax }
        return groups
    }

    static func readSeries(_ directory: URL, selected: String? = nil) throws -> Volume {
        let groups = try discover(directory)
        let group: Group
        if let selected {
            guard let match = groups[selected] else { throw DICOMError.missingSeries }
            group = match
        } else {
            let compatible = groups.values.filter { $0.nativePixels }
            guard !compatible.isEmpty else {
                throw groups.isEmpty ? DICOMError.emptyFolder : DICOMError.transferSyntax
            }
            guard compatible.count == 1, let only = compatible.first else {
                let options = compatible.map(\.option).sorted {
                    ($0.number ?? Int.max, -$0.slices, $0.id) < ($1.number ?? Int.max, -$1.slices, $1.id)
                }
                throw DICOMSeriesChoice(options: options)
            }
            group = only
        }
        guard group.nativePixels else { throw DICOMError.transferSyntax }
        guard group.files.count <= 2048, group.slices <= 2048 else { throw INVError.tooLarge }
        var images: [DICOMImage] = []
        var total = 0
        var frameCount = 0
        for file in group.files {
            if Task.isCancelled { throw CancellationError() }
            let data = try StudyFile.readDICOMMember(file)
            total += data.count
            guard total <= StudyFile.maxBytes else { throw INVError.tooLarge }
            let image = try DICOMImage(data)
            guard image.series == group.first.id else { throw DICOMError.geometry }
            frameCount += image.frames.count
            guard frameCount <= 2048 else { throw INVError.tooLarge }
            images.append(image)
        }
        var volume = try assemble(images, fingerprintSeries: true)
        if images.count == 1 {
            volume.legacyFingerprints = [volume.fingerprint!]
            volume.fingerprint = SHA256.hash(data: images[0].data).map { String(format: "%02x", $0) }.joined()
        }
        volume.dicomSeries = group.first.id
        volume.dicomSeriesNumber = group.first.number
        return volume
    }

    private static func assemble(_ images: [DICOMImage], fingerprintSeries: Bool = false) throws -> Volume {
        let first = images[0]
        let base = first.frames[0]
        let stackAxis = 3 - base.x.index - base.y.index
        let locations = images.indices.flatMap { image in images[image].frames.indices.map { (image, $0) } }
        guard locations.count <= 2048, first.columns * first.rows * locations.count <= StudyFile.maxSamples else {
            throw INVError.tooLarge
        }
        guard images.allSatisfy({ $0.columns == first.columns && $0.rows == first.rows &&
            $0.bits == first.bits && $0.stored == first.stored && $0.signed == first.signed &&
            $0.inverted == first.inverted && (images.count == 1 || first.reference != nil && $0.reference == first.reference)
        }) else { throw DICOMError.geometry }
        let positionTolerance = max(0.001, min(base.spacing.x, base.spacing.y) * 0.005)
        func geometry(_ item: (Int, Int)) -> DICOMFrame { images[item.0].frames[item.1] }
        guard locations.allSatisfy({ item in
            let frame = geometry(item)
            return frame.x == base.x && frame.y == base.y &&
                simd_distance(frame.spacing, base.spacing) < 0.000001 &&
                abs(frame.position[base.x.index] - base.position[base.x.index]) <= positionTolerance &&
                abs(frame.position[base.y.index] - base.position[base.y.index]) <= positionTolerance &&
                frame.slope == base.slope && frame.intercept == base.intercept
        }) else { throw DICOMError.geometry }
        let sorted = locations.sorted { geometry($0).position[stackAxis] < geometry($1).position[stackAxis] }
        let origin = geometry(sorted[0]).position[stackAxis]
        let dz = sorted.count > 1 ?
            (geometry(sorted[sorted.count - 1]).position[stackAxis] - origin) / Double(sorted.count - 1) :
            base.sliceSpacing ?? 0
        guard (0.001...100).contains(dz) else { throw DICOMError.geometry }
        let tolerance = max(0.001, dz * 0.005)
        guard sorted.enumerated().allSatisfy({ k, item in
            abs(geometry(item).position[stackAxis] - origin - Double(k) * dz) <= tolerance
        }), zip(sorted.dropFirst(), sorted).allSatisfy({ next, previous in
            let gap = geometry(next).position[stackAxis] - geometry(previous).position[stackAxis]
            return gap > 0 && abs(gap - dz) <= tolerance
        }) else { throw DICOMError.geometry }

        var dimensions = [0, 0, 0]
        dimensions[base.x.index] = first.columns
        dimensions[base.y.index] = first.rows
        dimensions[stackAxis] = sorted.count
        var spacing = [0.0, 0.0, 0.0]
        spacing[base.x.index] = base.spacing.x
        spacing[base.y.index] = base.spacing.y
        spacing[stackAxis] = dz

        let strides = [1, dimensions[0], dimensions[0] * dimensions[1]]
        let xStride = strides[base.x.index] * (base.x.forward ? 1 : -1)
        let yStride = strides[base.y.index] * (base.y.forward ? 1 : -1)
        let offset = (base.x.forward ? 0 : -xStride * (first.columns - 1))
                   + (base.y.forward ? 0 : -yStride * (first.rows - 1))
        let mask = UInt16((1 << first.stored) - 1)
        let bias: UInt16 = first.signed ? 1 << (first.stored - 1) : 0
        let frameSamples = first.rows * first.columns
        var pixels = [UInt16](repeating: 0, count: frameSamples * sorted.count)
        var minimum = UInt16.max
        var maximum: UInt16 = 0
        for (z, item) in sorted.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let image = images[item.0]
            let start = image.pixelRange.lowerBound + item.1 * frameSamples * (first.bits / 8)
            image.data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for row in 0..<first.rows {
                    let rowStart = offset + z * strides[stackAxis] + row * yStride
                    for column in 0..<first.columns {
                        let index = row * first.columns + column
                        let raw: UInt16 = first.bits == 16 ?
                            UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: start + index * 2, as: UInt16.self)) :
                            UInt16(bytes[start + index])
                        let sample = (raw & mask) ^ bias
                        let displayed = first.inverted ? mask - sample : sample
                        pixels[rowStart + column * xStride] = displayed
                        minimum = min(minimum, displayed)
                        maximum = max(maximum, displayed)
                    }
                }
            }
        }

        // Window values are expressed in modality units. Convert them back
        // into the monotonic sample domain used by the existing viewer.
        var windowCenter = (Double(minimum) + Double(maximum)) / 2
        var windowWidth = max(1, Double(maximum) - Double(minimum))
        if let center = base.center, let width = base.width {
            let correctedCenter = base.linearExact ? center : center - 0.5
            let correctedWidth = base.linearExact ? width : width - 1
            let rawCenter = (correctedCenter - base.intercept) / base.slope + Double(bias)
            let displayCenter = first.inverted ? Double(mask) - rawCenter : rawCenter
            let displayWidth = correctedWidth / base.slope
            if (0...65535).contains(displayCenter), (1...65535).contains(displayWidth) {
                windowCenter = displayCenter
                windowWidth = displayWidth
            }
        }
        var fingerprint: String?
        if fingerprintSeries {
            // Hash the files in patient slice order, without depending on names or modification times.
            let orderedImages = sorted.map(\.0)
            var seen = Set<Int>()
            var sha = SHA256()
            sha.update(data: Data("DICOM-series-v1".utf8))
            for image in orderedImages where seen.insert(image).inserted {
                sha.update(data: Data(SHA256.hash(data: images[image].data)))
            }
            fingerprint = sha.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return Volume(width: dimensions[0], height: dimensions[1], depth: dimensions[2], spacing: spacing,
                      oriented: true, windowWidth: windowWidth, windowCenter: windowCenter,
                      pixels: pixels, peak: maximum, fingerprint: fingerprint, invertedGrayscale: first.inverted)
    }
}
