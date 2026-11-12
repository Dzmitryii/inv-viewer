import Foundation
import simd

enum Fixture {
    private static let perBlock = 7
    static let opening = "<AppendedData encoding='raw'>"
    static let orientation = "<CaseInfo><ImageInfo><ImageOrientationPatient Value='1 0 0 0 1 0'/></ImageInfo></CaseInfo>"

    static func pixels() -> [UInt16] {
        let centers = (0...12).map { SyntheticStudy.archPoint(Double($0) / 12) }
        let count = SyntheticStudy.width * SyntheticStudy.height * SyntheticStudy.depth
        return (0..<count).map { index in
            let z = Double(index / (SyntheticStudy.width * SyntheticStudy.height)) * SyntheticStudy.spacing
            let x = Double(index % SyntheticStudy.width) * SyntheticStudy.spacing
            let y = Double(index / SyntheticStudy.width % SyntheticStudy.height) * SyntheticStudy.spacing
            let distance = centers.map { simd_length_squared(SIMD2(x, y) - $0) }.min()!
            if distance < 6.25 && ((8...12).contains(z) || (17...21).contains(z)) {
                return distance < 1 ? 2600 : 3500
            }
            if distance < 2.25 && ((4..<8).contains(z) || (21...25).contains(z)) { return 2400 }
            if distance < 18 && (z < 8 || z > 21) { return 1400 }
            let radius = hypot(x - 32, y - 32)
            return radius < 31 ? UInt16(200 + (index * 37 % 131)) : 0
        }
    }

    static func inv(pixels: [UInt16], directory: URL) throws -> Data {
        let width = SyntheticStudy.width, height = SyntheticStudy.height, depth = SyntheticStudy.depth
        let plane = width * height
        let spacing = SyntheticStudy.spacing
        let header = """
            <INVFile byteOrder='LittleEndian' version='2.0'>
            \(orientation)
            <Volume Dimensions='\(width) \(height) \(depth)' ScalarType='UInt16' NumComp='1' Offset='0'
                Source='Appended' Spacing='\(spacing) \(spacing) \(spacing)' CoordinateSystem='0 0 0 1 0 0 0'
                WindowLevel='4000 2000'/>
            \(opening)
            """
        let codestream = directory.appendingPathComponent("fixture.j2k")
        defer { try? FileManager.default.removeItem(at: codestream) }
        var blocks = [Data]()
        for start in stride(from: 0, to: depth, by: perBlock) {
            let frames = min(perBlock, depth - start)
            let success = pixels.withUnsafeBufferPointer {
                inv_encode_fixture_j2k(codestream.path, UInt32(width), UInt32(height), UInt32(frames),
                                       $0.baseAddress!.advanced(by: start * plane))
            }
            guard success == 1 else { throw CocoaError(.fileWriteUnknown) }
            blocks.append(try Data(contentsOf: codestream))
        }
        var data = Data(header.utf8)
        func append(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        append(0x5f202020)
        append(UInt32(blocks.count))
        append(UInt32(perBlock))
        append(UInt32(depth - (blocks.count - 1) * perBlock))
        for block in blocks { append(UInt32(block.count)) }
        for block in blocks { data.append(block) }
        data.append(contentsOf: "</AppendedData></INVFile>".utf8)
        return data
    }
}
