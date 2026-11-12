import CoreGraphics
import Foundation
import ImageIO
import Metal
import simd

struct VolumeRenderSettings {
    enum Preset: UInt32 { case bone, softTissue }

    var rotation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
    var preset: Preset = .bone
    var zoom: Float = 1
    var opacity: Float = 1
    var density: Float = 0
    var clipAxis: Plane?
    var clipFraction: Float = 0.5
    var reverseClip = false

    mutating func rotate(horizontal: Float, vertical: Float) {
        let yaw = simd_quatf(angle: horizontal, axis: SIMD3(0, 1, 0))
        let pitch = simd_quatf(angle: vertical, axis: SIMD3(1, 0, 0))
        rotation = simd_normalize(rotation * yaw * pitch)
    }
}

struct VolumeRenderGeometry {
    let sizeMM: SIMD3<Float>
    let voxelMM: SIMD3<Float>
    let diagonalMM: Float

    init(_ volume: Volume) {
        voxelMM = SIMD3(Float(volume.spacing[0]), Float(volume.spacing[1]), Float(volume.spacing[2]))
        sizeMM = SIMD3(Float(volume.width), Float(volume.height), Float(volume.depth)) * voxelMM
        diagonalMM = simd_length(sizeMM)
    }
}

private struct VolumeTone {
    let bone: SIMD3<Float>
    let softTissue: SIMD3<Float>

    init(_ volume: Volume) {
        // Sample throughout the volume, with a bounded histogram independent of texture size.
        var histogram = [Int](repeating: 0, count: 65536)
        var count = 0
        let step = max(1, volume.pixels.count / 131_072)
        for index in stride(from: 0, to: volume.pixels.count, by: step) {
            let value = volume.pixels[index]
            histogram[Int(volume.analysisValue(value))] += 1
            count += 1
        }
        func quantile(_ fraction: Double) -> Float {
            let rank = Int(Double(count - 1) * fraction)
            var total = 0
            for (index, frequency) in histogram.enumerated() {
                total += frequency
                if total > rank { return Float(index) / 65535 }
            }
            return 1
        }
        let background = quantile(0.02)
        let high = quantile(0.998)
        let range = max(0.0001, high - background)
        let boneStart = max(quantile(0.82), background + range * 0.20)
        let softStart = max(quantile(0.50), background + range * 0.12)
        let softPeak = max(softStart + range * 0.08, min(quantile(0.80), background + range * 0.60))
        bone = SIMD3(boneStart, max(boneStart + 0.0001, high), range)
        softTissue = SIMD3(softStart, softPeak, range)
    }
}

struct VolumeRenderData {
    fileprivate let texture: any MTLTexture
    fileprivate let geometry: VolumeRenderGeometry
    fileprivate let tone: VolumeTone
    fileprivate let inverted: Bool
}

enum VolumeRenderError: LocalizedError {
    case device, shader, allocation, render

    var errorDescription: String? {
        switch self {
        case .device: String(localized: "Для объёмного просмотра нужен Mac с поддержкой Metal.")
        case .shader: String(localized: "Не удалось запустить рендерер объёмного просмотра.")
        case .allocation: String(localized: "Не удалось разместить объём в памяти графического устройства.")
        case .render: String(localized: "Не удалось отрисовать объём.")
        }
    }
}

final class VolumeRenderer {
    // Each field occupies a full 16-byte vector in both Swift and Metal.
    private struct Uniforms {
        let right: SIMD4<Float>
        let up: SIMD4<Float>
        let towardViewer: SIMD4<Float>
        let extent: SIMD4<Float>
        let voxel: SIMD4<Float>
        let tone: SIMD4<Float>
        let controls: SIMD4<Float>
        let flags: SIMD4<UInt32>
    }

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState

    init(device: any MTLDevice, source: String) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw VolumeRenderError.device }
        self.queue = queue
        let library = try device.makeLibrary(source: source, options: nil)
        guard let raycast = library.makeFunction(name: "raycastVolume") else { throw VolumeRenderError.shader }
        pipeline = try device.makeComputePipelineState(function: raycast)
    }

    func upload(_ volume: Volume) throws -> VolumeRenderData {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Unorm
        descriptor.width = volume.width
        descriptor.height = volume.height
        descriptor.depth = volume.depth
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw VolumeRenderError.allocation }
        let region = MTLRegionMake3D(0, 0, 0, volume.width, volume.height, volume.depth)
        let row = volume.width * MemoryLayout<UInt16>.stride
        volume.pixels.withUnsafeBytes { pixels in
            texture.replace(region: region, mipmapLevel: 0, slice: 0, withBytes: pixels.baseAddress!,
                            bytesPerRow: row, bytesPerImage: row * volume.height)
        }
        return VolumeRenderData(texture: texture, geometry: VolumeRenderGeometry(volume),
                                tone: VolumeTone(volume), inverted: volume.invertedGrayscale)
    }

    func encode(_ data: VolumeRenderData, into target: any MTLTexture, settings: VolumeRenderSettings,
                interactive: Bool) throws -> any MTLCommandBuffer {
        let geometry = data.geometry
        let tone = settings.preset == .bone ? data.tone.bone : data.tone.softTissue
        let clipAxis: UInt32
        switch settings.clipAxis {
        case .sagittal: clipAxis = 0
        case .coronal: clipAxis = 1
        case .axial: clipAxis = 2
        case nil: clipAxis = 3
        }
        let rotation = settings.rotation
        var uniforms = Uniforms(
            right: SIMD4(rotation.act(SIMD3(1, 0, 0)), 0),
            up: SIMD4(rotation.act(SIMD3(0, 1, 0)), 0),
            towardViewer: SIMD4(rotation.act(SIMD3(0, 0, 1)), 0),
            extent: SIMD4(geometry.sizeMM / geometry.diagonalMM, geometry.diagonalMM),
            voxel: SIMD4(geometry.voxelMM / geometry.diagonalMM, 0),
            tone: SIMD4(tone, settings.density),
            controls: SIMD4(settings.zoom, settings.opacity, settings.clipFraction, interactive ? 300 : 720),
            flags: SIMD4(settings.preset.rawValue, clipAxis, settings.reverseClip ? 1 : 0, data.inverted ? 1 : 0)
        )
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw VolumeRenderError.render
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(data.texture, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / width))
        let groups = MTLSize(width: (target.width + width - 1) / width,
                             height: (target.height + height - 1) / height, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        return command
    }

    func capture(_ data: VolumeRenderData, settings: VolumeRenderSettings, width: Int,
                 height: Int) throws -> @Sendable () throws -> Data {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderWrite
        guard let target = device.makeTexture(descriptor: descriptor) else { throw VolumeRenderError.allocation }
        let command = try encode(data, into: target, settings: settings, interactive: false)
        if target.storageMode == .managed {
            guard let blit = command.makeBlitCommandEncoder() else { throw VolumeRenderError.render }
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        let finished = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in finished.signal() }
        command.commit()
        // The socket worker waits for GPU readback. AppKit stays free to handle input.
        return {
            guard finished.wait(timeout: .now() + 2) == .success,
                  command.status == .completed else { throw VolumeRenderError.render }
            let row = width * 4
            var pixels = Data(count: row * height)
            pixels.withUnsafeMutableBytes { buffer in
                target.getBytes(buffer.baseAddress!, bytesPerRow: row,
                                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            let bitmap = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
            let png = NSMutableData()
            guard let provider = CGDataProvider(data: pixels as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap,
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil)
            else { throw VolumeRenderError.render }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw VolumeRenderError.render }
            return png as Data
        }
    }
}
