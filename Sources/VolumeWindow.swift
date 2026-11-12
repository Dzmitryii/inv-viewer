import AppKit
import MetalKit

@MainActor
private final class VolumeCanvas: MTKView {
    var onOrbit: ((Float, Float, Bool) -> Void)?
    var onZoom: ((Double) -> Void)?
    var onLayout: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        onOrbit?(Float(event.deltaX) * 0.009, Float(event.deltaY) * 0.009, true)
    }

    override func mouseUp(with event: NSEvent) {
        onOrbit?(0, 0, false)
    }

    override func scrollWheel(with event: NSEvent) {
        onZoom?(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.012 : 0.08))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onOrbit?(-0.12, 0, false)
        case 124: onOrbit?(0.12, 0, false)
        case 125: onOrbit?(0, 0.12, false)
        case 126: onOrbit?(0, -0.12, false)
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class VolumeWindow: NSObject, NSWindowDelegate, MTKViewDelegate {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
    private let canvas = VolumeCanvas(frame: .zero)
    private let status = NSTextField(wrappingLabelWithString: String(localized: "Подготавливаю объёмный просмотр…"))
    private let preset = NSSegmentedControl(labels: [String(localized: "Кость"), String(localized: "Мягкие ткани")],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let density = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let opacity = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let zoom = NSSlider(value: 1, minValue: 0.65, maxValue: 3, target: nil, action: nil)
    private let axis = NSPopUpButton()
    private let clip = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let reverse = NSButton(checkboxWithTitle: String(localized: "Другая сторона"), target: nil, action: nil)
    private let orbitButtons = ["←", "→", "↑", "↓"].map { NSButton(title: $0, target: nil, action: nil) }
    private let reset = NSButton(title: String(localized: "Сбросить 3D"), target: nil, action: nil)
    private var settings = VolumeRenderSettings()
    private var preparation: Task<(VolumeRenderer, VolumeRenderData), Error>?
    private var renderSource: (VolumeRenderer, VolumeRenderData)?
    private var inFlight = false
    private var needsFrame = true
    private var interactive = false
    private var closed = false
    var onClose: (() -> Void)?
    var onActivate: (() -> Void)?

    init(volume: Volume) {
        super.init()
        window.title = String(localized: "Объёмный 3D")
        window.minSize = NSSize(width: 730, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        buildContent(oriented: volume.oriented)
        prepare(volume)
    }

    func show() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        if renderSource != nil { window.makeFirstResponder(canvas) }
        requestFrame()
    }

    func close() { window.close() }
    var isKeyWindow: Bool { window.isKeyWindow }
    var exportWindow: NSWindow { window }
    func windowDidBecomeKey(_ notification: Notification) { onActivate?() }

    func windowWillClose(_ notification: Notification) {
        closed = true
        preparation?.cancel()
        preparation = nil
        renderSource = nil
        canvas.device = nil
        onClose?()
    }

    func windowDidDeminiaturize(_ notification: Notification) { requestFrame() }

    private func buildContent(oriented: Bool) {
        preset.selectedSegment = 0
        preset.setAccessibilityLabel(String(localized: "Режим объёмного просмотра"))
        axis.addItem(withTitle: String(localized: "Без отсечения"))
        axis.addItems(withTitles: Plane.allCases.map { $0.title(oriented: oriented) })
        axis.setAccessibilityLabel(String(localized: "Плоскость отсечения"))
        clip.setAccessibilityLabel(String(localized: "Положение отсечения"))
        reset.target = self
        reset.action = #selector(resetView)
        for control in [preset, density, opacity, zoom, axis, clip, reverse] as [NSControl] {
            control.target = self
            control.action = #selector(updateSettings)
        }
        for slider in [density, opacity, zoom, clip] {
            slider.isContinuous = true
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        }
        let directions = [
            String(localized: "Повернуть влево"), String(localized: "Повернуть вправо"),
            String(localized: "Повернуть вверх"), String(localized: "Повернуть вниз")
        ]
        for (index, button) in orbitButtons.enumerated() {
            button.bezelStyle = .rounded
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
            button.tag = index
            button.target = self
            button.action = #selector(nudgeOrbit(_:))
            button.toolTip = directions[index]
            button.setAccessibilityLabel(directions[index])
        }

        canvas.isPaused = true
        canvas.enableSetNeedsDisplay = true
        canvas.autoResizeDrawable = false
        canvas.framebufferOnly = false
        canvas.colorPixelFormat = .bgra8Unorm
        canvas.delegate = self
        canvas.setAccessibilityLabel(String(localized: "Трёхмерное изображение снимка"))
        canvas.onLayout = { [weak self] in self?.requestFrame() }
        canvas.onOrbit = { [weak self] horizontal, vertical, moving in
            self?.orbit(horizontal: horizontal, vertical: vertical, moving: moving)
        }
        canvas.onZoom = { [weak self] delta in
            guard let self else { return }
            zoom.doubleValue = min(zoom.maxValue, max(zoom.minValue, zoom.doubleValue * exp(delta)))
            updateSettings()
        }

        let display = row([preset, label(String(localized: "Порог плотности"), for: density), density,
                           label(String(localized: "Непрозрачность"), for: opacity), opacity, reset])
        let clipping = row([label(String(localized: "Отсечение")), axis, clip, reverse, NSView(),
                            label(String(localized: "Масштаб"), for: zoom), zoom])
        let rotation = row([label(String(localized: "Поворот"))] + orbitButtons)
        let stage = NSView()
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor(srgbRed: 0.055, green: 0.070, blue: 0.089, alpha: 1).cgColor
        canvas.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        status.alignment = .center
        status.textColor = .white
        stage.addSubview(canvas)
        stage.addSubview(status)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: stage.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 275),
            status.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: stage.widthAnchor, constant: -48)
        ])
        let hint = label(String(localized: "Вращение — перетаскивание или стрелки. Масштаб — колесо или трекпад."))
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [display, clipping, rotation, stage, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            stage.widthAnchor.constraint(equalTo: stack.widthAnchor),
            display.widthAnchor.constraint(equalTo: stack.widthAnchor),
            clipping.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.contentView = content
        setReady(false)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func label(_ text: String, for control: NSControl? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        control?.setAccessibilityLabel(text)
        return field
    }

    private func prepare(_ volume: Volume) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            showError(.device)
            return
        }
        guard let shader = Bundle.main.url(forResource: "VolumeRaycast", withExtension: "metal") else {
            showError(.shader)
            return
        }
        let work = Task.detached(priority: .userInitiated) {
            let source = try String(contentsOf: shader, encoding: .utf8)
            let renderer = try VolumeRenderer(device: device, source: source)
            try Task.checkCancellation()
            return (renderer, try renderer.upload(volume))
        }
        preparation = work
        Task { [weak self] in
            let result = await work.result
            guard let self, !closed else { return }
            preparation = nil
            switch result {
            case .success(let source):
                renderSource = source
                canvas.device = device
                setReady(true)
                if window.isKeyWindow { window.makeFirstResponder(canvas) }
                requestFrame()
            case .failure(let error):
                showError(error as? VolumeRenderError ?? .shader)
            }
        }
    }

    private func setReady(_ ready: Bool) {
        for control in [preset, density, opacity, zoom, axis, reset] as [NSControl] { control.isEnabled = ready }
        for button in orbitButtons { button.isEnabled = ready }
        clip.isEnabled = ready && settings.clipAxis != nil
        reverse.isEnabled = clip.isEnabled
        canvas.isHidden = !ready
        status.isHidden = ready
    }

    private func showError(_ error: VolumeRenderError) {
        renderSource = nil
        status.stringValue = error.localizedDescription
        setReady(false)
    }

    @objc private func updateSettings() {
        settings.preset = preset.selectedSegment == 1 ? .softTissue : .bone
        settings.zoom = Float(zoom.doubleValue)
        settings.opacity = Float(opacity.doubleValue)
        settings.density = Float(density.doubleValue)
        settings.clipAxis = Plane(rawValue: axis.indexOfSelectedItem - 1)
        settings.clipFraction = Float(clip.doubleValue)
        settings.reverseClip = reverse.state == .on
        clip.isEnabled = settings.clipAxis != nil
        reverse.isEnabled = clip.isEnabled
        requestFrame()
    }

    @objc private func nudgeOrbit(_ sender: NSButton) {
        let step = Float.pi / 12
        switch sender.tag {
        case 0: orbit(horizontal: -step, vertical: 0, moving: false)
        case 1: orbit(horizontal: step, vertical: 0, moving: false)
        case 2: orbit(horizontal: 0, vertical: -step, moving: false)
        case 3: orbit(horizontal: 0, vertical: step, moving: false)
        default: break
        }
    }

    private func orbit(horizontal: Float, vertical: Float, moving: Bool) {
        settings.rotate(horizontal: horizontal, vertical: vertical)
        interactive = moving
        requestFrame()
    }

    var mcpState: [String: Any] {
        let rotation = settings.rotation.vector
        return [
            "view": MCPView.volume3D.rawValue, "render_ready": renderSource != nil,
            "preset": settings.preset == .bone ? "bone" : "soft_tissue",
            "zoom": settings.zoom, "opacity": settings.opacity, "density": settings.density,
            "clip_axis": settings.clipAxis.map { MCPView($0).rawValue } ?? "none",
            "clip_position": settings.clipFraction, "reverse_clip": settings.reverseClip,
            "rotation_xyzw": [rotation.x, rotation.y, rotation.z, rotation.w]
        ]
    }

    func configureMCP(_ args: ViewerCall.Arguments) throws {
        let yaw = args.yaw_deg ?? 0, pitch = args.pitch_deg ?? 0
        guard (-180...180).contains(yaw), (-180...180).contains(pitch),
              args.zoom.map({ (zoom.minValue...zoom.maxValue).contains($0) }) ?? true,
              args.opacity.map({ (0...1).contains($0) }) ?? true,
              args.density.map({ (-1...1).contains($0) }) ?? true,
              args.clip_position.map({ (0...1).contains($0) }) ?? true else {
            throw ViewerToolError(String(localized: "Параметры 3D вне допустимого диапазона."))
        }
        if args.reset == true { resetView() }
        if let value = args.preset { preset.selectedSegment = value == .bone ? 0 : 1 }
        if let value = args.zoom { zoom.doubleValue = value }
        if let value = args.opacity { opacity.doubleValue = value }
        if let value = args.density { density.doubleValue = value }
        if let value = args.clip_axis { axis.selectItem(at: (value.plane?.rawValue ?? -1) + 1) }
        if let value = args.clip_position { clip.doubleValue = value }
        if let value = args.reverse_clip { reverse.state = value ? .on : .off }
        settings.rotate(horizontal: Float(yaw * .pi / 180), vertical: Float(pitch * .pi / 180))
        interactive = false
        updateSettings()
    }

    func captureMCP() throws -> @Sendable () throws -> Data {
        try capturePNG(maxEdge: 768)
    }

    func capturePNG(maxEdge: Int = 1536) throws -> @Sendable () throws -> Data {
        guard let (renderer, input) = renderSource else {
            throw ViewerToolError(status.stringValue)
        }
        let size = canvas.bounds.size
        let edge = max(1, max(size.width, size.height))
        return try renderer.capture(input, settings: settings, width: max(1, Int(Double(maxEdge) * size.width / edge)),
                                    height: max(1, Int(Double(maxEdge) * size.height / edge)))
    }

    @objc private func resetView() {
        settings = VolumeRenderSettings()
        preset.selectedSegment = 0
        zoom.doubleValue = 1
        opacity.doubleValue = 1
        density.doubleValue = 0
        axis.selectItem(at: 0)
        clip.doubleValue = 0.5
        reverse.state = .off
        interactive = false
        updateSettings()
        window.makeFirstResponder(canvas)
    }

    private func requestFrame() {
        needsFrame = true
        guard renderSource != nil, !inFlight, window.isVisible, !window.isMiniaturized else { return }
        let pixels = canvas.convertToBacking(canvas.bounds).size
        let longest = max(pixels.width, pixels.height)
        guard longest >= 1 else { return }
        let scale = min(1, (interactive ? 480 : 960) / longest)
        let size = CGSize(width: max(1, (pixels.width * scale).rounded()),
                          height: max(1, (pixels.height * scale).rounded()))
        if canvas.drawableSize != size { canvas.drawableSize = size }
        canvas.needsDisplay = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard needsFrame, !inFlight, !closed, window.isVisible, !window.isMiniaturized,
              let (renderer, input) = renderSource, let drawable = view.currentDrawable else { return }
        do {
            let command = try renderer.encode(input, into: drawable.texture, settings: settings, interactive: interactive)
            inFlight = true
            needsFrame = false
            command.addCompletedHandler { [weak self] command in
                let completed = command.status == .completed
                Task { @MainActor [weak self] in
                    guard let self, !closed else { return }
                    inFlight = false
                    if !completed { showError(.render) }
                    else if needsFrame { requestFrame() }
                }
            }
            command.present(drawable)
            command.commit()
        } catch {
            showError(.render)
        }
    }
}
