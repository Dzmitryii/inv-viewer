import AppKit
import simd

@MainActor
final class MPRView: NSStackView {
    private enum Tool: Int { case move, rotate, ruler }
    private struct Measurement {
        let plane: Plane
        let frame: MPRFrame
        let first: SIMD3<Double>
        var second: SIMD3<Double>?
    }

    private struct Rotation {
        let plane: Plane
        let frame: MPRFrame
        let pose: MPRPose
        let angle: Double
    }

    private let sliceViews = Plane.allCases.map { _ in SliceView(frame: .zero) }
    private let titles = Plane.allCases.map { _ in NSTextField(labelWithString: "—") }
    private let primary = NSSegmentedControl(labels: ["1", "2", "3"], trackingMode: .selectOne, target: nil, action: nil)
    private let tools = NSSegmentedControl(labels: [String(localized: "Курсор"), String(localized: "Наклон"), String(localized: "Линейка")],
                                           trackingMode: .selectOne, target: nil, action: nil)
    private let guidance = NSTextField(labelWithString: "")
    private let coordinates = NSTextField(labelWithString: "")
    private let saveRuler = NSButton(title: String(localized: "Сохранить измерение…"), target: nil, action: nil)
    private let erase = NSButton(title: String(localized: "Очистить линейку"), target: nil, action: nil)
    private let resetTilt = NSButton(title: String(localized: "Сбросить наклон"), target: nil, action: nil)
    private let tiltLeft = NSButton(title: "−5°", target: nil, action: nil)
    private let tiltRight = NSButton(title: "+5°", target: nil, action: nil)
    private let columns = NSStackView()
    private let references = NSStackView()
    private var panels = [NSStackView]()
    private var panelLayout = [NSLayoutConstraint]()
    private var frames = [MPRFrame]()
    private var windowSetting = GrayWindow(width: 4000, center: 2000)
    private var lastWindow: GrayWindow?
    private var volume: Volume?
    private var active = false
    private var queued = false
    private var measurement: Measurement?
    private var rotation: Rotation?
    private(set) var pose = MPRPose(point: .zero)
    private(set) var activePlane = Plane.axial
    private(set) var mainPlane = Plane.axial
    var onAdjustDisplay: ((CGFloat, CGFloat) -> Void)? {
        didSet { for view in sliceViews { view.onAdjustDisplay = onAdjustDisplay } }
    }
    var onSaveMeasurement: (() -> Void)?
    var onOpen: ((URL) -> Void)?

    private var tool: Tool { Tool(rawValue: tools.selectedSegment) ?? .move }
    private let colors: [NSColor] = [.systemCyan, .systemOrange, .systemPurple]

    override init(frame: CGRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = 6

        for plane in Plane.allCases {
            let i = plane.rawValue
            let image = sliceViews[i], title = titles[i]
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            title.textColor = .labelColor
            title.lineBreakMode = .byTruncatingTail
            image.inset = 18
            image.setContentHuggingPriority(.defaultLow, for: .vertical)
            image.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            image.onOpen = { [weak self] in self?.onOpen?($0) }
            image.onPoint = { [weak self] in self?.pick($0, in: plane) }
            image.resetsPanOnDoubleClick = false
            image.onStep = { [weak self] in self?.step($0, in: plane) }
            image.onPlane = { [weak self] in
                if let target = Plane(rawValue: $0) { self?.enlarge(target) }
            }
            image.onGestureStart = { [weak self] point, modifiers in
                self?.beginGesture(point, in: plane, modifiers: modifiers) ?? false
            }
            image.onGestureMove = { [weak self] point in self?.rotate(to: point) }
            image.onGestureEnd = { [weak self] in self?.rotation = nil }
            image.overlay = { [weak self] context, rect in self?.drawGuides(context, rect: rect, in: plane) }
            let panel = NSStackView(views: [title, image])
            panel.orientation = .vertical
            panel.alignment = .leading
            panel.spacing = 3
            image.widthAnchor.constraint(equalTo: panel.widthAnchor).isActive = true
            panels.append(panel)
        }

        primary.target = self
        primary.action = #selector(selectPrimary)
        primary.setAccessibilityLabel(String(localized: "Крупная плоскость"))
        tools.target = self
        tools.action = #selector(selectTool)
        tools.selectedSegment = Tool.move.rawValue
        tools.setAccessibilityLabel(String(localized: "Инструмент MPR"))
        wire(resetTilt, #selector(resetOrientation))
        wire(tiltLeft, #selector(rotateLeft))
        wire(tiltRight, #selector(rotateRight))
        wire(saveRuler, #selector(saveMeasurement))
        wire(erase, #selector(eraseRuler))
        tiltLeft.setAccessibilityLabel(String(localized: "Повернуть направляющие на минус пять градусов"))
        tiltRight.setAccessibilityLabel(String(localized: "Повернуть направляющие на плюс пять градусов"))

        let mainLabel = NSTextField(labelWithString: String(localized: "Крупно"))
        mainLabel.font = .systemFont(ofSize: 11)
        let toolbar = NSStackView(views: [tools, tiltLeft, tiltRight, resetTilt, erase, saveRuler, NSView(), mainLabel, primary])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        for field in [guidance, coordinates] {
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 7
        references.orientation = .vertical
        references.alignment = .leading
        references.distribution = .fillEqually
        references.spacing = 7
        for subview in [toolbar, guidance, columns, coordinates] {
            addArrangedSubview(subview)
            subview.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        arrangePanels()
        selectTool()
    }

    required init?(coder: NSCoder) { nil }

    private func wire(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
    }

    func load(_ volume: Volume) {
        self.volume = volume
        let middle = SIMD3(Double(volume.width / 2), Double(volume.height / 2), Double(volume.depth / 2))
        pose = MPRPose(point: middle * volume.spacingVector)
        activePlane = .axial
        mainPlane = .axial
        frames = []
        lastWindow = nil
        measurement = nil
        rotation = nil
        tools.selectedSegment = Tool.move.rawValue
        for plane in Plane.allCases {
            let image = sliceViews[plane.rawValue]
            image.image = nil
            image.resetPan()
            image.setAccessibilityLabel("MPR · " + plane.title(oriented: volume.oriented))
            primary.setLabel(["XY", "XZ", "YZ"][plane.rawValue], forSegment: plane.rawValue)
        }
        arrangePanels()
        selectTool()
        schedule()
    }

    func setActive(_ active: Bool) {
        self.active = active
        if active {
            schedule()
            focus()
        } else {
            rotation = nil
        }
    }

    func setDisplay(_ gray: GrayWindow, zoom: Double) {
        windowSetting = gray
        for plane in Plane.allCases {
            let view = sliceViews[plane.rawValue]
            if view.zoom != zoom {
                view.setZoom(zoom, centeredAt: frames.count == sliceViews.count ? unitCursor(in: plane) : nil)
            }
        }
        schedule()
    }

    func goTo(_ point: SIMD3<Double>) {
        guard let volume, volume.containsMPRPoint(point) else { return }
        apply(MPRPose(point: point), plane: .axial, main: .axial)
    }

    func apply(_ pose: MPRPose, plane: Plane, main: Plane) {
        self.pose = pose
        activePlane = plane
        mainPlane = main
        measurement = nil
        rotation = nil
        tools.selectedSegment = Tool.move.rawValue
        arrangePanels()
        for view in sliceViews { view.resetPan() }
        selectTool()
        schedule()
    }

    func step(_ amount: Int, in plane: Plane) {
        guard let volume else { return }
        activePlane = plane
        if pose.isStraight {
            let axis = plane.normalAxis
            let current = Int((pose.point[axis] / volume.spacing[axis]).rounded())
            setSlice(current + amount, in: plane)
        } else {
            let direction = pose.normal(for: plane)
            pose.point = volume.movedMPRPoint(pose.point, along: direction,
                                              by: Double(amount) * volume.spacing.min()!)
            schedule()
        }
    }

    func setSlice(_ index: Int, in plane: Plane) {
        guard let volume, pose.isStraight else { return }
        activePlane = plane
        pose.point[plane.normalAxis] = Double(min(volume.sliceCount(plane) - 1, max(0, index))) *
            volume.spacing[plane.normalAxis]
        schedule()
    }

    var exportFrame: ExportFrame? {
        guard !queued, var result = sliceViews[activePlane.rawValue].exportFrame else { return nil }
        if let measurement, let second = measurement.second, savedRuler != nil {
            result.ruler = ExportRuler(first: measurement.frame.project(measurement.first),
                                       second: measurement.frame.project(second),
                                       distance: simd_distance(measurement.first, second))
        }
        return result
    }

    func currentImage(in plane: Plane) -> CGImage? {
        queued ? nil : sliceViews[plane.rawValue].image
    }

    private func schedule() {
        guard active, !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false
            if active { render() }
        }
    }

    private func render() {
        guard let volume else { return }
        let nextFrames = Plane.allCases.map { MPRFrame(volume, plane: $0, pose: pose) }
        let previous = frames
        frames = nextFrames
        for plane in Plane.allCases {
            let i = plane.rawValue, frame = frames[i], view = sliceViews[i]
            if !previous.indices.contains(i) || frame != previous[i] || lastWindow != windowSetting {
                view.aspect = frame.size.x / frame.size.y
                view.sideLabels = volume.oriented ? frame.sideLabels : []
                view.image = volume.mprImage(frame, gray: windowSetting)
            }
            view.reveal(unitCursor(in: plane))
            view.needsDisplay = true
        }
        lastWindow = windowSetting
        if let measurement, measurement.frame != frames[measurement.plane.rawValue] {
            self.measurement = nil
        }
        updateReadout()
    }

    private func unitCursor(in plane: Plane) -> CGPoint {
        let point = frames[plane.rawValue].project(pose.point)
        return CGPoint(x: point.x, y: point.y)
    }

    @objc private func selectPrimary() {
        if let plane = Plane(rawValue: primary.selectedSegment) { enlarge(plane) }
    }

    private func enlarge(_ plane: Plane) {
        mainPlane = plane
        activePlane = plane
        arrangePanels()
        updateReadout()
        focus()
    }

    private func focus() {
        if active { window?.makeFirstResponder(sliceViews[activePlane.rawValue]) }
    }

    private func arrangePanels() {
        NSLayoutConstraint.deactivate(panelLayout)
        for panel in panels { panel.removeFromSuperview() }
        references.removeFromSuperview()
        let big = panels[mainPlane.rawValue]
        columns.addArrangedSubview(big)
        columns.addArrangedSubview(references)
        panelLayout = [
            big.heightAnchor.constraint(equalTo: columns.heightAnchor),
            big.widthAnchor.constraint(equalTo: columns.widthAnchor, multiplier: 0.66, constant: -columns.spacing),
            references.heightAnchor.constraint(equalTo: columns.heightAnchor),
            references.widthAnchor.constraint(equalTo: columns.widthAnchor, multiplier: 0.34)
        ]
        for plane in Plane.allCases where plane != mainPlane {
            let panel = panels[plane.rawValue]
            references.addArrangedSubview(panel)
            panelLayout.append(panel.widthAnchor.constraint(equalTo: references.widthAnchor))
        }
        NSLayoutConstraint.activate(panelLayout)
        primary.selectedSegment = mainPlane.rawValue
    }

    @objc private func selectTool() {
        rotation = nil
        for plane in Plane.allCases {
            let image = sliceViews[plane.rawValue]
            if tool == .move {
                image.onDoubleClick = { [weak self] in self?.enlarge(plane) }
            } else {
                image.onDoubleClick = nil
            }
        }
        updateReadout()
        focus()
    }

    @objc private func resetOrientation() {
        pose = MPRPose(point: pose.point)
        rotation = nil
        measurement = nil
        schedule()
        focus()
    }

    @objc private func rotateLeft() { nudge(-Double.pi / 36) }
    @objc private func rotateRight() { nudge(Double.pi / 36) }

    private func nudge(_ radians: Double) {
        pose.rotate(radians, in: activePlane)
        measurement = nil
        schedule()
        focus()
    }

    var savedRuler: SavedRuler? {
        guard let volume, let measurement, let second = measurement.second,
              measurement.plane == activePlane,
              measurement.frame == MPRFrame(volume, plane: activePlane, pose: pose) else { return nil }
        return .mpr(first: measurement.first, second: second)
    }

    func restoreRuler(_ saved: SavedRuler, in plane: Plane? = nil) {
        guard let volume, case .mpr(let first, let second) = saved else { return }
        if let plane { activePlane = plane }
        tools.selectedSegment = Tool.ruler.rawValue
        measurement = Measurement(plane: activePlane, frame: MPRFrame(volume, plane: activePlane, pose: pose),
                                  first: first, second: second)
        selectTool()
    }

    @objc private func saveMeasurement() { onSaveMeasurement?() }

    @objc private func eraseRuler() {
        measurement = nil
        for view in sliceViews { view.needsDisplay = true }
        updateReadout()
        focus()
    }

    private func pick(_ point: CGPoint, in plane: Plane) {
        guard let volume, frames.count == sliceViews.count else { return }
        activePlane = plane
        let frame = frames[plane.rawValue]
        let location = frame.location(SIMD2(point.x, point.y))
        guard volume.containsMPRPoint(location) else { updateReadout(); return }
        if tool == .ruler {
            if var current = measurement, current.plane == plane, current.frame == frame, current.second == nil {
                current.second = location
                measurement = current
            } else {
                measurement = Measurement(plane: plane, frame: frame, first: location)
            }
            for view in sliceViews { view.needsDisplay = true }
            updateReadout()
        } else if tool == .move {
            pose.point = location
            schedule()
        }
    }

    private func beginGesture(_ point: CGPoint, in plane: Plane, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard frames.count == sliceViews.count, tool == .rotate || modifiers.contains(.shift) else { return false }
        activePlane = plane
        let frame = frames[plane.rawValue]
        let delta = (SIMD2(point.x, point.y) - frame.project(pose.point)) * frame.size
        if simd_length(delta) >= 1 {
            rotation = Rotation(plane: plane, frame: frame, pose: pose, angle: atan2(delta.y, delta.x))
        }
        updateReadout()
        return true
    }

    private func rotate(to point: CGPoint) {
        guard let rotation else { return }
        let frame = rotation.frame
        let delta = (SIMD2(point.x, point.y) - frame.project(rotation.pose.point)) * frame.size
        guard simd_length(delta) >= 1 else { return }
        let handedness = simd_dot(simd_cross(frame.right, frame.down), frame.normal)
        pose = rotation.pose
        pose.rotate(handedness * (atan2(delta.y, delta.x) - rotation.angle), in: rotation.plane)
        measurement = nil
        schedule()
    }

    private func updateReadout() {
        let oriented = volume?.oriented == true
        for plane in Plane.allCases {
            let name = plane.title(oriented: oriented)
            let isActive = plane == activePlane
            let i = plane.rawValue
            let offset = frames.indices.contains(i) ? frames[i].offset : 0
            let position: String
            if let volume, simd_distance(pose.normal(for: plane), plane.normalVector) < 1e-8 {
                let slice = Int((pose.point[plane.normalAxis] / volume.spacing[plane.normalAxis]).rounded()) + 1
                position = "\(min(volume.sliceCount(plane), max(1, slice))) / \(volume.sliceCount(plane))"
            } else {
                position = String(localized: "косой · \(mm(offset)) мм")
            }
            titles[i].stringValue = "\(isActive ? "● " : "")\(name)  ·  \(position)"
            sliceViews[i].frameColor = isActive ? colors[i] : nil
            sliceViews[i].setAccessibilityValue(position)
        }
        resetTilt.isEnabled = !pose.isStraight
        erase.isEnabled = measurement != nil
        saveRuler.isHidden = savedRuler == nil
        tiltLeft.isEnabled = tool == .rotate
        tiltRight.isEnabled = tool == .rotate
        tiltLeft.isHidden = tool != .rotate
        tiltRight.isHidden = tool != .rotate
        resetTilt.isHidden = tool != .rotate && pose.isStraight
        erase.isHidden = tool != .ruler && measurement == nil
        switch tool {
        case .move: guidance.stringValue = String(localized: "Щелчок ставит курсор · Колесо листает · Двойной щелчок увеличивает плоскость")
        case .rotate: guidance.stringValue = String(localized: "Тяните вокруг перекрестия или используйте −5° / +5° · Поворот влияет на две другие плоскости")
        case .ruler: guidance.stringValue = String(localized: "Щёлкните две точки в одной плоскости · Следующий щелчок начинает новое измерение")
        }
        if let measurement {
            if let end = measurement.second {
                coordinates.stringValue = String(localized: "Расстояние  \(mm(simd_distance(measurement.first, end))) мм")
            } else {
                coordinates.stringValue = String(localized: "Линейка · Укажите вторую точку на том же срезе")
            }
        } else {
            let point = [pose.point.x, pose.point.y, pose.point.z].map(mm).joined(separator: " / ")
            coordinates.stringValue = String(localized: "Курсор X / Y / Z от начала объёма  \(point) мм")
        }
    }

    private func mm(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(1)))
    }

    private func drawGuides(_ context: CGContext, rect: CGRect, in plane: Plane) {
        guard frames.count == sliceViews.count else { return }
        let frame = frames[plane.rawValue]
        func display(_ world: SIMD3<Double>) -> CGPoint {
            let unit = frame.project(world)
            return CGPoint(x: rect.minX + unit.x * rect.width, y: rect.maxY - unit.y * rect.height)
        }
        func line(_ from: CGPoint, _ to: CGPoint, color: NSColor) {
            for (stroke, width) in [(NSColor.black.withAlphaComponent(0.8), 3.0), (color, 1.25)] {
                context.setStrokeColor(stroke.cgColor)
                context.setLineWidth(width)
                context.move(to: from)
                context.addLine(to: to)
                context.strokePath()
            }
        }
        let span = simd_length(frame.size)
        for other in Plane.allCases where other != plane {
            let direction = simd_cross(frame.normal, pose.normal(for: other)) * span
            let gap = direction * 0.007
            let color = colors[other.rawValue]
            line(display(pose.point - direction), display(pose.point - gap), color: color)
            line(display(pose.point + gap), display(pose.point + direction), color: color)
        }
        guard let measurement, measurement.plane == plane, measurement.frame == frame else { return }
        RulerOverlay.draw(in: context, first: display(measurement.first),
                          second: measurement.second.map(display),
                          distance: measurement.second.map { simd_distance(measurement.first, $0) },
                          viewport: rect.intersection(sliceViews[plane.rawValue].bounds))
    }
}
