import Foundation
import Metal
import simd

enum VolumeRenderingFixture {
    static func verify(shader: URL, demo: Volume) throws {
        let pixels = (0..<(30 * 20 * 15)).map { index -> UInt16 in
            let x = index % 30, y = (index / 30) % 20, z = index / 600
            if (7..<16).contains(x) && (3..<16).contains(y) && (4..<11).contains(z) { return 7000 }
            if (19..<25).contains(x) && (6..<16).contains(y) && (3..<12).contains(z) { return 2500 }
            return 100
        }
        let volume = Volume(width: 30, height: 20, depth: 15, spacing: [0.4, 0.9, 0.7], oriented: true,
                            windowWidth: 6000, windowCenter: 3200, pixels: pixels)
        let geometry = VolumeRenderGeometry(volume)
        precondition(simd_distance(geometry.sizeMM, SIMD3<Float>(12, 18, 10.5)) < 0.001)
        var settings = VolumeRenderSettings()
        precondition(simd_distance(settings.rotation.act(SIMD3(0, 1, 0)), SIMD3(0, 0, 1)) < 0.001)
        settings.rotate(horizontal: 0.4, vertical: -0.6)
        precondition(abs(simd_length(settings.rotation.vector) - 1) < 0.001)

        guard let device = MTLCreateSystemDefaultDevice() else {
            print("SKIP · Metal GPU volume rendering (no Metal device on this host)")
            return
        }
        let renderer = try VolumeRenderer(device: device, source: String(contentsOf: shader, encoding: .utf8))
        let data = try renderer.upload(volume)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 160, height: 120, mipmapped: false)
        descriptor.usage = .shaderWrite
        guard let image = device.makeTexture(descriptor: descriptor) else { throw VolumeRenderError.allocation }
        func render(_ input: VolumeRenderData, _ settings: VolumeRenderSettings) throws -> [UInt8] {
            let command = try renderer.encode(input, into: image, settings: settings, interactive: false)
            if image.storageMode == .managed {
                guard let blit = command.makeBlitCommandEncoder() else { throw VolumeRenderError.render }
                blit.synchronize(resource: image)
                blit.endEncoding()
            }
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else { throw command.error ?? VolumeRenderError.render }
            var bytes = [UInt8](repeating: 0, count: 160 * 120 * 4)
            image.getBytes(&bytes, bytesPerRow: 160 * 4, from: MTLRegionMake2D(0, 0, 160, 120), mipmapLevel: 0)
            return bytes
        }
        let bone = try render(data, VolumeRenderSettings())
        let rotated = try render(data, settings)
        precondition(bone != rotated)
        settings = VolumeRenderSettings()
        settings.preset = .softTissue
        let softTissue = try render(data, settings)
        precondition(softTissue != bone)
        settings.clipAxis = .sagittal
        settings.clipFraction = 0
        let clipped = try render(data, settings)
        precondition(Set(stride(from: 0, to: clipped.count, by: 4).map { clipped[$0] }).count == 1)
        settings.reverseClip = true
        let reversed = try render(data, settings)
        precondition(reversed == softTissue)
        let demoData = try renderer.upload(demo)
        let demoBone = try render(demoData, VolumeRenderSettings())
        precondition(Set(stride(from: 0, to: demoBone.count, by: 4).map { demoBone[$0] }).count > 24)
        print("PASS · Metal volume rendering of anisotropic fixture and CBCT demo, orbit, presets and clipping")
    }
}
