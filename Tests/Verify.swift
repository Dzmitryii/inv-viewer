import CoreGraphics
import Foundation
import ImageIO
import simd
import Darwin

@main
enum Verify {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil) // Keep completed checks visible if a later assertion terminates the process.
        let arguments = CommandLine.arguments
        guard arguments.count >= 4, (arguments.count - 4) % 3 == 0 else {
            fatalError("Usage: Verify fixture.inv demo.inv demo-arches.json [--reference scan reference.npy]...")
        }
        let fixtureURL = URL(fileURLWithPath: arguments[1])
        let working = fixtureURL.deletingLastPathComponent()
        let demo = try Volume.read(URL(fileURLWithPath: arguments[2]))
        let demoArches = try DemoStudy.arches(at: URL(fileURLWithPath: arguments[3]), for: demo)
        precondition(demo.oriented && demo.width == 400 && demo.height == 400 && demo.depth == 300)
        let demoGray = GrayWindow(width: demo.windowWidth, center: demo.windowCenter)
        for arch in [demoArches.upper!, demoArches.lower!] {
            let curve = ArchCurve(nodes: SavedArch.orderedNodes(arch.nodes), resolution: demo.archResolution)!
            precondition(demo.panoramicImage(curve, thickness: 8, offset: 0, window: demoGray) != nil)
            precondition(demo.crossImage(curve, at: curve.points.count / 2, width: 30, offset: 0, window: demoGray) != nil)
        }
        print("PASS · clinical demo decoded and both arches rendered with cross-sections")
        try VolumeRenderingFixture.verify(shader: URL(fileURLWithPath: arguments[3]).deletingLastPathComponent()
            .appendingPathComponent("VolumeRaycast.metal"), demo: demo)

        let expectedPixels = Fixture.pixels()
        let file = try Fixture.inv(pixels: expectedPixels, directory: working)
        try file.write(to: fixtureURL)
        let volume = try Volume.read(fixtureURL)
        precondition(volume.pixels == expectedPixels)
        precondition(volume.oriented && volume.spacing == [0.5, 0.5, 0.5])
        precondition(volume.windowWidth == 4000 && volume.windowCenter == 2000)
        print("PASS · all generated voxels survived a multi-block lossless INV round trip")

        try DICOMFixture.verify(in: working)
        try AuditRegression.verify(in: working, phantom: volume)
        try BackupFixture.verify(in: working, volume: volume)
        await AuditRegression.verifyCancellation(file: fixtureURL, volume: volume)
        for index in stride(from: 4, to: arguments.count, by: 3) {
            let kind = arguments[index]
            let input = URL(fileURLWithPath: arguments[index + 1])
            let npy = URL(fileURLWithPath: arguments[index + 2])
            let decoded = try verifyReference(input, npy: npy, demo: kind == "--demo-reference" ? demo : nil)
            if kind == "--auto-arch-reference" {
                let start = DispatchTime.now()
                let arches = AutomaticArches.estimate(in: decoded)
                precondition(arches.valid(in: decoded) && arches.lower != nil && arches.upper != nil)
                let lower = arches.lower!, upper = arches.upper!
                // Independently marked dental levels on the local 407-slice export.
                precondition((75...115).contains(lower.axial) && (120...155).contains(upper.axial))
                let gray = GrayWindow(width: decoded.windowWidth, center: decoded.windowCenter)
                for arch in [lower, upper] {
                    let curve = ArchCurve(nodes: arch.nodes, resolution: decoded.archResolution)!
                    let pano = decoded.panoramicImage(curve, thickness: 8, offset: 0, window: gray)!
                    precondition(pano.height == 407 && pano.width > 200)
                }
                let ms = (DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                print("PASS · 407-slice export, automatic arches at axial frames \(lower.axial + 1) and \(upper.axial + 1), rendered both panoramas (\(ms) ms)")
            }
            if kind == "--dicom-reference" {
                precondition(decoded.oriented && decoded.width == demo.width && decoded.height == demo.height &&
                             decoded.depth == demo.depth && zip(decoded.spacing, demo.spacing).allSatisfy { abs($0 - $1) < 1e-8 })
                let arch = ArchCurve(nodes: demoArches.upper!.nodes, resolution: demo.archResolution)!
                let gray = GrayWindow(width: demo.windowWidth, center: demo.windowCenter)
                let referencePanorama = demo.panoramicImage(arch, thickness: 8, offset: 0, window: gray)!
                let dicomPanorama = decoded.panoramicImage(arch, thickness: 8, offset: 0, window: gray)!
                precondition(referencePanorama.dataProvider!.data! == dicomPanorama.dataProvider!.data!)
                print("PASS · local DICOM and INV agree in scale, orientation and panoramic pixels at the same window")
            }
        }

        let synthetic = Volume(width: 3, height: 2, depth: 2, spacing: [1, 2, 3], oriented: true,
                               windowWidth: 255, windowCenter: 127.5, pixels: Array(0...11))
        let expected: [[UInt8]] = [[6, 7, 8, 9, 10, 11], [9, 10, 11, 3, 4, 5], [7, 10, 1, 4]]
        for plane in Plane.allCases {
            let image = synthetic.image(plane, index: 1, windowWidth: 255, center: 127.5)!
            precondition((image.dataProvider!.data! as Data).elementsEqual(expected[plane.rawValue]))
        }
        precondition(synthetic.sliceSize(.coronal).aspect == 0.5)
        precondition(synthetic.sliceSize(.sagittal).aspect == 4.0 / 6)
        precondition(Plane.axial.labels == ["R", "L", "A", "P"])
        print("PASS · all three planes, pixel order, physical aspect ratios and axis labels")
        verifyPanorama(volume)
        verifyAutomaticArches(volume)
        verifyMPR(synthetic, study: volume)
        try verifyNotes(volume)
        try verifyLibrary(volume, at: working)
        try verifyContainerVariants(file, expected: expectedPixels)
        try verifyPNG(volume)

        let payload = file.range(of: Data(Fixture.opening.utf8))!.upperBound
        var spoofed = file
        let orientation = file.range(of: Data(Fixture.orientation.utf8))!
        spoofed.replaceSubrange(orientation, with:
            Data("<Unrelated><ImageOrientationPatient Value='1 0 0 0 1 0'/></Unrelated>".utf8))
        let spoofedVolume = try Volume.decode(spoofed)
        precondition(!spoofedVolume.oriented, "Unrelated metadata must not set anatomical orientation")
        var deeplyNested = file
        deeplyNested.replaceSubrange(orientation, with:
            Data((String(repeating: "<n>", count: 70) + String(repeating: "</n>", count: 70)).utf8))
        try reject(deeplyNested)
        let fifo = working.appendingPathComponent("non-regular.inv")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        defer { _ = unlink(fifo.path) }
        do {
            _ = try Volume.read(fifo)
            fatalError("A FIFO was accepted as a file")
        } catch INVError.unsupported {}

        let count = Int(file[payload + 4])
        let codestream = payload + 16 + 4 * count
        try reject(Data("invalid".utf8))
        try reject(Data(file.prefix(file.count - 128)))
        var overflow = file
        overflow.replaceSubrange((payload + 16)..<(payload + 20), with: [255, 255, 255, 255])
        try reject(overflow)
        var smallTile = file
        smallTile.replaceSubrange((codestream + 24)..<(codestream + 32), with: [0, 0, 0, 1, 0, 0, 0, 1])
        try reject(smallTile)
        var corrupt = file
        // Keep SIZ and EOC intact and damage the next JPEG 2000 marker.
        let marker = codestream + 6 + Int(file[codestream + 4]) * 256 + Int(file[codestream + 5])
        corrupt.replaceSubrange(marker..<(marker + 2), with: [0, 0])
        try reject(corrupt)
        var entity = file
        let root = file.range(of: Data("<INVFile".utf8))!.lowerBound
        entity.insert(contentsOf: Data("<!DOCTYPE INVFile SYSTEM 'file:///etc/passwd'>".utf8), at: root)
        try reject(entity)
        print("PASS · invalid format, truncation, oversized block, tile exhaustion, corrupt JPEG 2000, metadata spoofing, XML depth, DTD and FIFO")
    }

    static func verifyAutomaticArches(_ volume: Volume) {
        let result = AutomaticArches.estimate(in: volume)
        precondition(result.valid(in: volume))
        guard let upper = result.upper, let lower = result.lower else {
            fatalError("No paired arches in the dental phantom")
        }
        precondition((14...24).contains(lower.axial) && (32...43).contains(upper.axial))
        let first = lower.nodes[lower.nodes.count / 2]
        let second = upper.nodes[upper.nodes.count / 2]
        precondition(simd_distance(first, SyntheticStudy.archPoint(0.5)) < 7 &&
                     simd_distance(second, SyntheticStudy.archPoint(0.5)) < 7)
        for arch in [upper, lower] {
            let right = simd_distance(arch.nodes.first!, SyntheticStudy.archPoint(0))
            let left = simd_distance(arch.nodes.last!, SyntheticStudy.archPoint(1))
            precondition(right < 5 && left < 5,
                         "Phantom terminal teeth missed (right: \(right) mm, left: \(left) mm)")
        }
        let uniform = Volume(width: volume.width, height: volume.height, depth: volume.depth,
                             spacing: volume.spacing, oriented: true, windowWidth: volume.windowWidth,
                             windowCenter: volume.windowCenter, pixels: Array(repeating: 1200, count: volume.pixels.count))
        precondition(AutomaticArches.estimate(in: uniform) == StudyArches())
        print("PASS · automatic arches reach all four terminal teeth in the phantom; no arch proposed on a uniform scan")
    }

    static func verifyPanorama(_ study: Volume) {
        let voxels = (0..<192).map { i -> UInt16 in
            let z = i / 64, y = i / 8 % 8, x = i % 8
            return UInt16(10 * z + 2 * y + x + (y == 3 ? 8 : 0))
        }
        let volume = Volume(width: 8, height: 8, depth: 3, spacing: [1, 2, 3], oriented: true,
                            windowWidth: 255, windowCenter: 127.5, pixels: voxels)
        let nodes: [SIMD2<Double>] = [SIMD2(1, 4), SIMD2(3, 4), SIMD2(6, 4)]
        let curve = ArchCurve(nodes: nodes, resolution: 1)!
        precondition(curve.length == 5 && curve.points.count == 6)
        precondition(curve.normals.allSatisfy { $0 == SIMD2(0, 1) })
        precondition(ArchCurve(nodes: [nodes[0], nodes[0], nodes[1]], resolution: 1) == nil)
        let length = PlanarDistance.millimeters(from: SIMD2(0.2, 0.3), to: SIMD2(0.5, 0.7),
                                                 extent: SIMD2(30, 60))
        precondition(abs(length - hypot(9, 24)) < 1e-8)
        let gray = GrayWindow(width: 255, center: 127.5)
        func pixels(_ image: CGImage?) -> Data { image!.dataProvider!.data! as Data }
        let thin = pixels(volume.panoramicImage(curve, thickness: 0, offset: 0, window: gray))
        let thick = pixels(volume.panoramicImage(curve, thickness: 4, offset: 0, window: gray))
        let offset = pixels(volume.panoramicImage(curve, thickness: 0, offset: 2, window: gray))
        precondition(thin.prefix(6).elementsEqual(25...30) && thin.suffix(6).elementsEqual(5...10))
        precondition(thick.prefix(6).elementsEqual(27...32))
        precondition(offset.prefix(6).elementsEqual(35...40))
        let cross = pixels(volume.crossImage(curve, at: 2, width: 4, offset: 0, window: gray))
        precondition(cross.prefix(4).elementsEqual([26, 27, 30, 35]))

        let presets = SyntheticStudy.defaultArches(for: study)
        precondition(presets.valid(in: study))
        let studyGray = GrayWindow(width: study.windowWidth, center: study.windowCenter)
        for preset in [presets.upper!, presets.lower!] {
            let arch = ArchCurve(nodes: preset.nodes, resolution: study.archResolution)!
            precondition((80...115).contains(arch.length))
            let image = study.panoramicImage(arch, thickness: 8, offset: 0, window: studyGray)!
            precondition(image.width == arch.points.count && image.height == SyntheticStudy.depth)
            precondition(Set(pixels(image)).count > 8)
            let mid = arch.points.count / 2
            let cross = study.crossImage(arch, at: mid, width: 30, offset: 0, window: studyGray)!
            let next = study.crossImage(arch, at: mid + 10, width: 30, offset: 0, window: studyGray)!
            precondition(cross.width == 60 && cross.height == SyntheticStudy.depth && pixels(cross) != pixels(next))
        }
        print("PASS · panoramic geometry, slab and offset, perpendicular sections, and both patient arches")
    }

    static func verifyMPR(_ synthetic: Volume, study: Volume) {
        let gray = GrayWindow(width: 255, center: 127.5)
        func pixels(_ image: CGImage?) -> Data { image!.dataProvider!.data! as Data }
        for volume in [synthetic, study] {
            let point = SIMD3(volume.spacing[0], volume.spacing[1], volume.spacing[2])
            for plane in Plane.allCases {
                let frame = MPRFrame(volume, plane: plane, pose: MPRPose(point: point))
                let old = volume.image(plane, index: 1, windowWidth: gray.width, center: gray.center)
                precondition(pixels(volume.mprImage(frame, gray: gray)) == pixels(old))
                let uv = frame.project(point)
                precondition(simd_distance(frame.location(uv), point) < 1e-8)
            }
        }
        var pose = MPRPose(point: SIMD3(1, 1, 1.5))
        precondition(abs(synthetic.interpolatedVoxel(pose.point)! - 5.5) < 1e-8)
        precondition(synthetic.interpolatedVoxel(SIMD3(-1, 0, 0)) == nil)
        let before = MPRFrame(synthetic, plane: .axial, pose: pose)
        pose.rotate(.pi / 4, in: .axial)
        let fixed = MPRFrame(synthetic, plane: .axial, pose: pose)
        precondition(simd_distance(before.right, fixed.right) < 1e-8)
        let tilted = MPRFrame(synthetic, plane: .coronal, pose: pose)
        precondition(abs(tilted.normal.x + sqrt(0.5)) < 1e-8)
        let first = tilted.location(SIMD2(0.3, 0.3))
        let second = tilted.location(SIMD2(0.7, 0.6))
        let expected = hypot(0.4 * tilted.size.x, 0.3 * tilted.size.y)
        precondition(abs(simd_distance(first, second) - expected) < 1e-8)
        precondition(abs(simd_dot(first - second, tilted.normal)) < 1e-8)
        precondition(synthetic.mprImage(tilted, gray: gray) != nil)
        print("PASS · linked MPR geometry, anisotropic distances, axis parity, tilt and interpolation")
    }

    @MainActor
    static func verifyPNG(_ volume: Volume) throws {
        let image = volume.image(.axial, index: volume.depth / 2, windowWidth: 4000, center: 2000)!
        let frame = ExportFrame(image: image, aspect: 1, labels: Plane.axial.labels,
                                ruler: ExportRuler(first: SIMD2(0.25, 0.5), second: SIMD2(0.75, 0.5), distance: 32))
        func inspect(_ data: Data) -> (Int, Int, Bool) {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let w = image.width, h = image.height
            let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                        CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            let hasRulerColor = (0..<(w * h)).contains {
                let i = $0 * 4
                return pixels[i] > 200 && pixels[i + 1] > 140 && pixels[i + 2] < 110
            }
            return (w, h, hasRulerColor)
        }
        let plain = try inspect(PNGExport.encode(frame, includeRuler: false))
        let annotated = try inspect(PNGExport.encode(frame, includeRuler: true))
        precondition(plain == (156, 156, false) && annotated == (156, 156, true))
        print("PASS · PNG decode, output dimensions, ruler rasterized only when requested")
    }

    static func verifyContainerVariants(_ file: Data, expected: [UInt16]) throws {
        let original = file.range(of: Data(Fixture.opening.utf8))!
        for tag in ["<AppendedData encoding=\"raw\">", "<AppendedData\n  encoding = 'raw' >"] {
            var variant = file
            variant.replaceSubrange(original, with: Data(tag.utf8))
            let volume = try Volume.decode(variant)
            precondition(volume.pixels == expected && volume.oriented)
        }
        for tag in ["<AppendedData encoding='base64'>", "<AppendedData encoding='raw' source='foreign'>"] {
            var variant = file
            variant.replaceSubrange(original, with: Data(tag.utf8))
            try reject(variant)
        }
        print("PASS · equivalent XML header variants keep voxels and orientation; unknown encodings are rejected")
    }

    static func verifyLibrary(_ volume: Volume, at working: URL) throws {
        let root = working.appendingPathComponent("library-test", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibrary.store(at: root)
        let recents = RecentScans.store(at: root)
        let links = [volume.fingerprint!, String(repeating: "a", count: 64)].enumerated().map { i, hash in
            ScanLink(bookmark: Data([UInt8(i)]), fileName: "fixture.inv", fingerprint: hash)
        }
        let studies = links.enumerated().map { i, link in
            PatientStudy(title: "Visit \(i + 1)", date: Date(timeIntervalSince1970: Double(i) * 86400), link: link)
        }
        let first = LibraryPatient(name: "Patient 1", studies: studies)
        let other = LibraryPatient(name: "Patient 2", studies: [studies[1]])
        let empty = StudyLibrary()
        let library = StudyLibrary(patients: [first, other])
        try store.write(library, replacing: empty, default: empty, valid: { $0.valid })
        let restored = try StudyLibrary.store(at: root).read(default: empty, valid: { $0.valid })
        precondition(restored == library)
        var duplicate = restored
        duplicate.patients[0].studies.append(PatientStudy(title: "Same bytes", date: Date(), link: links[0]))
        do {
            try store.write(duplicate, replacing: restored, default: empty, valid: { $0.valid })
            fatalError("Duplicate was accepted")
        } catch StudyStoreError.invalid {}
        var renamed = restored
        renamed.patients[0].name = "Patient 1 revised"
        try store.write(renamed, replacing: restored, default: empty, valid: { $0.valid })
        do {
            try store.write(empty, replacing: restored, default: empty, valid: { $0.valid })
            fatalError("Stale view could delete the newer catalog")
        } catch StudyStoreError.changed {}

        var recent = RecentScans()
        for link in [links[0], links[1], links[0]] { recent.record(link) }
        try recents.write(recent, replacing: RecentScans(), default: RecentScans(), valid: { $0.valid })
        let history = try recents.read(default: RecentScans(), valid: { $0.valid })
        precondition(history.links == links)
        let kept = try store.read(default: empty, valid: { $0.valid })
        precondition(kept == renamed && kept.patients[1] == other)
        print("PASS · patient and study isolation, durable library and recent history, duplicate and stale writes rejected")
    }

    static func verifyNativeMPRPerformance(_ volume: Volume) {
        let voxel = SIMD3(Double(volume.width / 2), Double(volume.height / 2), Double(volume.depth / 2))
        let pose = MPRPose(point: voxel * volume.spacingVector)
        let gray = GrayWindow(width: volume.windowWidth, center: volume.windowCenter)
        let frames = Plane.allCases.map { MPRFrame(volume, plane: $0, pose: pose) }
        for frame in frames {
            let native = volume.mprImage(frame, gray: gray)!
            let reference = volume.interpolatedMPRImage(frame, gray: gray)!
            precondition(native.dataProvider!.data! == reference.dataProvider!.data!)
        }
        func timed(_ render: (MPRFrame, GrayWindow) -> CGImage?) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<12 {
                for frame in frames { precondition(render(frame, gray) != nil) }
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 36_000_000
        }
        let direct = timed(volume.mprImage)
        let trilinear = timed(volume.interpolatedMPRImage)
        print(String(format: "PASS · private native MPR matched interpolated pixels; mean per plane %.2f vs %.2f ms", direct, trilinear))
    }

    static func verifyNotes(_ study: Volume) throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StudyStore(root: directory, fingerprint: study.fingerprint!)!
        let other = StudyStore(root: directory, fingerprint: String(repeating: "a", count: 64))!
        var notes = StudyNotes()
        let archivedNotes = try JSONDecoder().decode(StudyNotes.self, from: Data(#"{"version":1,"bookmarks":[]}"#.utf8))
        precondition(archivedNotes == notes)
        let arches = AutomaticArches.estimate(in: study)
        let old = arches.upper!
        let oldCurve = ArchCurve(nodes: old.nodes, resolution: study.archResolution)!
        let oldPanorama = SavedPanorama(jaw: 0, arch: old, section: oldCurve.points.count / 2,
                                       thickness: 8, offset: 0, widthIndex: 0, intervalIndex: 0, detailed: false,
                                       showSections: true, showGuides: true)
        let oldView = SavedViewingState(display: SavedDisplay(width: 4000, level: 2000, zoom: 1),
                                       location: .panorama(oldPanorama), ruler: nil)
        var legacy = StudyNotes()
        legacy.automaticArches = arches
        legacy.automaticArchRevision = AutomaticArches.revision - 1
        legacy.lastView = oldView
        legacy.lower = SyntheticStudy.defaultArches(for: study).lower
        precondition(legacy.needsAutomaticArches)
        let refreshed = legacy.withAutomaticArches(SyntheticStudy.defaultArches(for: study))
        precondition(!refreshed.needsAutomaticArches && refreshed.lastView == nil && refreshed.lower == legacy.lower)
        let protected = StudyBookmark(name: "Preserved view", display: oldView.display, location: oldView.location)
        legacy.bookmarks = [protected]
        legacy.lastBookmark = protected.id
        let withBookmark = legacy.withAutomaticArches(SyntheticStudy.defaultArches(for: study))
        precondition(withBookmark.lastView == oldView && withBookmark.bookmarks == [protected] &&
                     withBookmark.lastBookmark == protected.id)
        notes.baseline = SyntheticStudy.defaultArches(for: study)
        notes = notes.withAutomaticArches(arches)
        notes.upper = notes.baseline?.upper
        var pose = MPRPose(point: SIMD3(20, 23, 14))
        pose.rotate(0.43, in: .sagittal)
        let mark = StudyBookmark(name: "Проверка", display: SavedDisplay(width: 4000, level: 2000, zoom: 2),
                                 location: .mpr(pose, plane: Plane.coronal.rawValue, main: Plane.axial.rawValue))
        notes.bookmarks = [mark]
        let mpr = MPRPose(point: SIMD3(32.0, 32.0, 12.0))
        let display = SavedDisplay(width: 4000, level: 2000, zoom: 1)
        let at = StudyBookmark.Location.mpr(mpr, plane: 0, main: 0)
        let reading = SavedRuler.mpr(first: mpr.point, second: mpr.point + SIMD3(3.0, 4.0, 0.0))
        precondition(reading.distance(in: study, at: at) == 5)
        let annotated = StudyBookmark(name: "MPR ruler", display: display, location: at, ruler: reading,
                                      annotation: "First line\nSecond line")
        notes.bookmarks.append(annotated)
        notes.lastView = annotated.viewingState
        notes.lastBookmark = annotated.id
        let arch = notes.baseline!.upper!
        let curve = ArchCurve(nodes: arch.nodes, resolution: study.archResolution)!
        let detail = SavedPanorama(jaw: 0, arch: arch, section: curve.points.count / 2, thickness: 8,
                                   offset: 0, widthIndex: 0, intervalIndex: 0, detailed: true,
                                   showSections: true, showGuides: true)
        let section = SavedRuler.section(first: SIMD2(0.45, 0.5), second: SIMD2(0.55, 0.5))
        precondition(abs(section.distance(in: study, at: .panorama(detail))! - 2) < 1e-8)
        notes.bookmarks.append(StudyBookmark(name: "Section ruler", display: display, location: .panorama(detail), ruler: section))
        try store.write(notes, replacing: StudyNotes(), volume: study)
        let restored = try store.read(volume: study)
        precondition(restored == notes)
        precondition(restored.lastView?.ruler?.distance(in: study, at: at) == 5)
        precondition(restored.bookmarks.first { $0.id == restored.lastBookmark }?.annotation == "First line\nSecond line")
        let invalidRuler = SavedRuler.mpr(first: mpr.point, second: mpr.point + SIMD3(3.0, 4.0, 0.5))
        precondition(invalidRuler.distance(in: study, at: at) == nil)
        let isolated = try other.read(volume: study)
        precondition(isolated == StudyNotes())
        var invalid = notes
        invalid.upper = SavedArch(nodes: [], axial: 170)
        do {
            try store.write(invalid, replacing: notes, volume: study)
            fatalError("Invalid notes replaced the existing study state")
        } catch is StudyStoreError {}
        do {
            try store.write(StudyNotes(), replacing: StudyNotes(), volume: study)
            fatalError("A stale instance replaced the existing study state")
        } catch StudyStoreError.changed {}
        let retained = try store.read(volume: study)
        precondition(retained == notes)
        print("PASS · study isolation, bookmark, annotations, last view and arch round trip, rejected write preserves saved data")
    }

    static func verifyReference(_ input: URL, npy: URL, demo: Volume?) throws -> Volume {
        let volume = try Volume.read(input)
        let reference = try Data(contentsOf: npy, options: .mappedIfSafe)
        precondition(reference.count >= 10 && reference.prefix(8) == Data([147, 78, 85, 77, 80, 89, 1, 0]))
        let headerLength = Int(reference[8]) + 256 * Int(reference[9])
        precondition(reference.count >= 10 + headerLength)
        let header = String(decoding: reference[10..<(10 + headerLength)], as: UTF8.self)
        let shape = "(\(volume.depth), \(volume.height), \(volume.width))"
        precondition(header.contains("'<u2'") && header.contains(shape) && header.contains("False"))
        precondition(volume.pixels.withUnsafeBytes { $0.elementsEqual(reference[(10 + headerLength)...]) })
        print("PASS · optional private reference matched all \(volume.pixels.count) voxels")
        if let demo {
            precondition(demo.pixels == volume.pixels && demo.spacing == volume.spacing && demo.oriented == volume.oriented &&
                         demo.windowWidth == volume.windowWidth && demo.windowCenter == volume.windowCenter)
            print("PASS · demo and original have identical voxels, spacing, orientation, and grayscale settings")
        }
        verifyNativeMPRPerformance(volume)
        return volume
    }

    static func reject(_ bytes: Data) throws {
        do {
            _ = try Volume.decode(bytes)
            fatalError("Malformed input was accepted")
        } catch is INVError {
            return
        }
    }
}
