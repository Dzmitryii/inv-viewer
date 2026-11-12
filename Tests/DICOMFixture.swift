import Foundation

enum DICOMFixture {
    private static func encoded<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    private static func element(_ tag: UInt32, _ vr: String, _ bytes: Data, explicit: Bool,
                                undefined: Bool = false) -> Data {
        var data = encoded(UInt16(tag >> 16)) + encoded(UInt16(truncatingIfNeeded: tag))
        if explicit && tag >> 16 != 0xfffe {
            data += Data(vr.utf8)
            if ["SQ", "OB", "OW"].contains(vr) {
                data += encoded(UInt16(0))
                data += encoded(undefined ? UInt32.max : UInt32(bytes.count))
            } else {
                data += encoded(UInt16(bytes.count))
            }
        } else {
            data += encoded(undefined ? UInt32.max : UInt32(bytes.count))
        }
        return data + bytes
    }

    private static func text(_ value: String, vr: String) -> Data {
        var bytes = Data(value.utf8)
        if bytes.count % 2 != 0 { bytes.append(vr == "UI" ? 0 : 32) }
        return bytes
    }

    static func image(z: [Double], values: [UInt16], explicit: Bool = true, signed: Bool = false,
                      orientation: String = "1\\0\\0\\0\\1\\0", series: String = "1.2.3.4",
                      syntax: String? = nil, photo: String = "MONOCHROME2", storageClass: String? = nil) -> Data {
        var file = Data(repeating: 0, count: 128) + Data("DICM".utf8)
        file += element(0x00020010, "UI", text(syntax ?? (explicit ? "1.2.840.10008.1.2.1" : "1.2.840.10008.1.2"), vr: "UI"),
                        explicit: true)
        let multiframe = z.count > 1
        func string(_ tag: UInt32, _ vr: String, _ value: String) -> Data {
            element(tag, vr, text(value, vr: vr), explicit: explicit)
        }
        func us(_ tag: UInt32, _ value: UInt16) -> Data { element(tag, "US", encoded(value), explicit: explicit) }
        func item(_ body: Data) -> Data {
            element(0xfffee000, "", body + element(0xfffee00d, "", Data(), explicit: explicit),
                    explicit: explicit, undefined: true)
        }
        func sequence(_ tag: UInt32, _ items: [Data]) -> Data {
            let body = items.reduce(into: Data()) { $0 += item($1) }
            return element(tag, "SQ", body + element(0xfffee0dd, "", Data(), explicit: explicit),
                           explicit: explicit, undefined: true)
        }
        file += string(0x00080016, "UI", storageClass ?? (multiframe ? "1.2.840.10008.5.1.4.1.1.2.1" : "1.2.840.10008.5.1.4.1.1.2"))
        file += string(0x0020000e, "UI", series)
        file += string(0x00200052, "UI", "1.2.3.5")
        file += us(0x00280002, 1)
        file += string(0x00280004, "CS", photo)
        file += us(0x00280010, 2)
        file += us(0x00280011, 3)
        file += us(0x00280100, 16)
        file += us(0x00280101, 12)
        file += us(0x00280102, 11)
        file += us(0x00280103, signed ? 1 : 0)
        file += string(0x00281050, "DS", "400")
        file += string(0x00281051, "DS", "2000")
        file += string(0x00281052, "DS", "-1000")
        file += string(0x00281053, "DS", "1")
        if multiframe {
            file += string(0x00280008, "IS", String(z.count))
            let measures = string(0x00280030, "DS", "0.4\\0.7") + string(0x00180050, "DS", "1.3")
            file += sequence(0x52009229, [
                sequence(0x00289110, [measures]) +
                sequence(0x00209116, [string(0x00200037, "DS", orientation)])
            ])
            file += sequence(0x52009230, z.map { position in
                sequence(0x00209113, [string(0x00200032, "DS", "5\\9\\\(position)")])
            })
        } else {
            file += string(0x00200032, "DS", "5\\9\\\(z[0])")
            file += string(0x00200037, "DS", orientation)
            file += string(0x00280030, "DS", "0.4\\0.7")
            file += string(0x00180050, "DS", "1.3")
        }
        return file + element(0x7fe00010, "OW", values.reduce(into: Data()) { $0 += encoded($1) }, explicit: explicit)
    }

    static func verify(in directory: URL) throws {
        let low: [UInt16] = [0, 1, 2, 3, 4, 5]
        let high: [UInt16] = [6, 7, 8, 9, 10, 11]
        let enhanced = try DICOM.decode(image(z: [1.3, 0], values: high + low))
        precondition(enhanced.width == 3 && enhanced.height == 2 && enhanced.depth == 2 && enhanced.oriented)
        precondition(enhanced.spacing == [0.7, 0.4, 1.3] && enhanced.pixels == low + high)
        precondition(enhanced.windowCenter == 1399.5 && enhanced.windowWidth == 1999)

        let reversed = try DICOM.decode(image(z: [0], values: low, orientation: "-1\\0\\0\\0\\1\\0"))
        precondition(reversed.pixels == [2, 1, 0, 5, 4, 3])
        let swapped = try DICOM.decode(image(z: [0], values: low, orientation: "0\\1\\0\\1\\0\\0"))
        precondition(swapped.width == 2 && swapped.height == 3 && swapped.spacing == [0.4, 0.7, 1.3])
        precondition(swapped.pixels == [0, 3, 1, 4, 2, 5])

        let root = directory.appendingPathComponent("synthetic-dicom-series", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let subfolder = root.appendingPathComponent("DICOM/CT", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let late = subfolder.appendingPathComponent("a.dcm")
        let early = subfolder.appendingPathComponent("z")
        try image(z: [0], values: low, series: "1.2.3.50", storageClass: "1.2.840.10008.5.1.4.1.1.1.1")
            .write(to: root.appendingPathComponent("projection.dcm"))
        try image(z: [0], values: low, series: "1.2.3.51", syntax: "1.2.840.10008.1.2.4.50")
            .write(to: root.appendingPathComponent("compressed.dcm"))
        let signedLow: [UInt16] = [0xfffe, 0x0fff, 0, 1, 2, 3]
        try image(z: [1.3], values: high, explicit: false, signed: true).write(to: late)
        try image(z: [0], values: signedLow, explicit: false, signed: true).write(to: early)
        try Data("notes".utf8).write(to: root.appendingPathComponent("readme.txt"))
        let series = try Volume.read(root)
        precondition(series.pixels == [2046, 2047, 2048, 2049, 2050, 2051] + high.map { $0 + 2048 })
        precondition(series.spacing == [0.7, 0.4, 1.3] && series.fingerprint?.count == 64)
        precondition(series.dicomSeries == "1.2.3.4")
        let renamed = subfolder.appendingPathComponent("00.dicom")
        try FileManager.default.moveItem(at: early, to: renamed)
        let sameSeries = try Volume.read(root)
        precondition(sameSeries.fingerprint == series.fingerprint)

        let mono1 = try DICOM.decode(image(z: [0], values: low, photo: "MONOCHROME1"))
        precondition(mono1.pixels == low.map { 4095 - $0 })
        try reject(.transferSyntax) {
            try DICOM.decode(image(z: [0], values: low, syntax: "1.2.840.10008.1.2.4.90"))
        }
        try reject(.damaged) { try DICOM.decode(Data(image(z: [0], values: low).dropLast())) }
        try reject(.geometry) { try DICOM.decode(image(z: [0, 0], values: low + high)) }
        try reject(.geometry) { try DICOM.decode(image(z: [0, 1.3, 3], values: low + high + low)) }
        try reject(.geometry) {
            try DICOM.decode(image(z: [0], values: low, orientation: "0.6\\0.8\\0\\-0.8\\0.6\\0"))
        }
        try image(z: [2.6], values: low, series: "1.2.3.99").write(to: root.appendingPathComponent("other.dcm"))
        do {
            _ = try Volume.read(root)
            fatalError("A series was silently selected")
        } catch let choice as DICOMSeriesChoice {
            precondition(choice.options.count == 2 && choice.options.contains {
                $0.id == series.dicomSeries && $0.slices == 2 && $0.width == 3 && $0.height == 2
            })
        }
        let selected = try Volume.read(root, dicomSeries: series.dicomSeries)
        precondition(selected.fingerprint == series.fingerprint && selected.pixels == series.pixels)
        try reject(.missingSeries) { try Volume.read(root, dicomSeries: "1.2.3.90") }
        try image(z: [2.6], values: low, series: "1.2.3.4", syntax: "1.2.840.10008.1.2.4.50")
            .write(to: subfolder.appendingPathComponent("incompatible-member.dcm"))
        try reject(.transferSyntax) { try Volume.read(root, dicomSeries: series.dicomSeries) }
        print("PASS · DICOM geometry, nested discovery, projection filtering, explicit selection and incomplete-series rejection")
    }

    private static func reject(_ expected: DICOMError, _ read: () throws -> Volume) throws {
        do {
            _ = try read()
            fatalError("Invalid DICOM accepted")
        } catch let error as DICOMError {
            precondition(error == expected)
        }
    }
}
