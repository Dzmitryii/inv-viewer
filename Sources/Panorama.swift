import AppKit
import simd

@MainActor
final class Panorama: NSStackView {
    private let preview = SliceView(frame: .zero)
    private let axial = SliceView(frame: .zero)
    private let sections = (0..<3).map { _ in SliceView(frame: .zero) }
    private let sectionTitles = (0..<3).map { _ in NSTextField(labelWithString: "—") }
    private let detail = SliceView(frame: .zero)
    private let backToPanorama = NSButton(title: String(localized: "К панораме"), target: nil, action: nil)
    private let previousSection = NSButton(title: String(localized: "Предыдущий"), target: nil, action: nil)
    private let nextSection = NSButton(title: String(localized: "Следующий"), target: nil, action: nil)
    private let sendPoint = NSButton(title: String(localized: "В MPR"), target: nil, action: nil)
    private let sendDetailPoint = NSButton(title: String(localized: "В MPR"), target: nil, action: nil)
    private let settings = NSButton(title: String(localized: "Параметры"), target: nil, action: nil)
    private let inspector = NSBox()
    private let detailRuler = NSButton(checkboxWithTitle: String(localized: "Линейка"), target: nil, action: nil)
    private let saveRuler = NSButton(title: String(localized: "Сохранить измерение…"), target: nil, action: nil)
    private let detailMeasurementLabel = NSTextField(labelWithString: "")
    private let returnToCurrent = NSButton(title: String(localized: "К текущей дуге"), target: nil, action: nil)
    private let jaw = NSSegmentedControl(labels: [String(localized: "Верхняя дуга"), String(localized: "Нижняя дуга")],
                                         trackingMode: .selectOne, target: nil, action: nil)
    private let edit = NSButton(title: String(localized: "Править дугу"), target: nil, action: nil)
    private let new = NSButton(title: String(localized: "Новая дуга"), target: nil, action: nil)
    private let cancel = NSButton(title: String(localized: "Отмена"), target: nil, action: nil)
    private let undoPoint = NSButton(title: String(localized: "Убрать точку"), target: nil, action: nil)
    private let restore = NSButton(title: String(localized: "Исходная дуга"), target: nil, action: nil)
    private let showSections = NSButton(checkboxWithTitle: String(localized: "Срезы по дуге"), target: nil, action: nil)
    private let showGuides = NSButton(checkboxWithTitle: String(localized: "Линии"), target: nil, action: nil)
    private let position = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let slice = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let thickness = NSSlider(value: 8, minValue: 0, maxValue: 20, target: nil, action: nil)
    private let offset = NSSlider(value: 0, minValue: -10, maxValue: 10, target: nil, action: nil)
    private let sectionWidth = NSPopUpButton(frame: .zero, pullsDown: false)
    private let interval = NSPopUpButton(frame: .zero, pullsDown: false)
    private let positionText = NSTextField(labelWithString: String(localized: "Положение на дуге"))
    private let sliceText = NSTextField(labelWithString: String(localized: "Аксиальный срез"))
    private let thicknessText = NSTextField(labelWithString: String(localized: "Слой 8 мм"))
    private let offsetText = NSTextField(labelWithString: String(localized: "Смещение 0 мм"))
    private let setupGuide = NSTextField(wrappingLabelWithString:
        String(localized: "1. Выберите челюсть. 2. Прокрутите аксиальные срезы до уровня, где виден ряд зубов. 3. Нажмите «Построить дугу» и расставьте точки по центрам зубов."))
    private let help = NSTextField(labelWithString: "")
    private var initialZ = [0, 0]
    private var automaticOriginal = [false, false]
    private var volume: Volume?
    private var originals: [[SIMD2<Double>]] = [[], []]
    private var nodes: [[SIMD2<Double>]] = [[], []]
    private var bookmarkNodes: [SIMD2<Double>]?
    private var draft: [SIMD2<Double>]?
    private var draggedNode: Int?
    private var axialPositions = [0, 0]
    private var archPositions = [0.5, 0.5]
    private var curve: ArchCurve?
    private var renderTask: Task<CGImage?, Never>?
    private var updateScheduled = false
    private var needsPanorama = false
    private var needsAxial = false
    private var needsCross = false
    private var crossCache: [Int: CGImage] = [:]
    private var crossCacheDisplay: GrayWindow?
    private var crossCacheWidth = 0.0
    private var crossCacheOffset = 0.0
    private var gray = GrayWindow(width: 4000, center: 2000)
    private var active = false
    private var lowerPane: NSStackView?
    private weak var crossPanes: NSStackView?
    private var overviewWidths: [NSLayoutConstraint] = []
    private var setupWidth: NSLayoutConstraint?
    private var splitRatio: NSLayoutConstraint?
    private var fullStageWidth: NSLayoutConstraint?
    private var reducedStageWidth: NSLayoutConstraint?
    private var overviewControls = [NSView]()
    private var detailControls: NSStackView?
    private var isDetailed = false
    private var rulerFirst: SIMD2<Double>?
    private var rulerSecond: SIMD2<Double>?
    var onAdjustDisplay: ((CGFloat, CGFloat) -> Void)? {
        didSet {
            for view in [preview, axial, detail] + sections { view.onAdjustDisplay = onAdjustDisplay }
        }
    }
    var onSaveMeasurement: (() -> Void)?
    var onSaveArch: ((Int, SavedArch?) -> Bool)?
    var onMoveToMPR: ((SIMD3<Double>) -> Void)?

    private var jawIndex: Int { max(0, jaw.selectedSegment) }
    private var currentNodes: [SIMD2<Double>] { bookmarkNodes ?? nodes[jawIndex] }
    private var axialIndex: Int { axialPositions[jawIndex] }
    private var selected: Int { Int(position.doubleValue.rounded()) }
    private var slab: Double { thickness.doubleValue.rounded() }
    private var displacement: Double { (offset.doubleValue * 2).rounded() / 2 }
    private var crossWidth: Double { [20.0, 30, 40][max(0, sectionWidth.indexOfSelectedItem)] }
    private var crossInterval: Double { [1.0, 2, 3][max(0, interval.indexOfSelectedItem)] }
    private var crossStep: Int {
        guard let curve else { return 1 }
        return max(1, Int((crossInterval / curve.step).rounded()))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        alignment = .top
        spacing = 10
        jaw.selectedSegment = 0
        jaw.setAccessibilityLabel(String(localized: "Дуга челюсти"))
        wire(jaw, #selector(selectJaw))
        wire(edit, #selector(toggleEdit))
        wire(new, #selector(startNew))
        wire(cancel, #selector(cancelEdit))
        wire(undoPoint, #selector(removeDraftPoint))
        wire(restore, #selector(restoreArch))
        wire(showSections, #selector(updateLayout))
        wire(showGuides, #selector(updateLayout))
        wire(position, #selector(moveOnArch))
        wire(slice, #selector(moveAxial))
        wire(thickness, #selector(changeSlab))
        wire(offset, #selector(changeSlab))
        wire(sectionWidth, #selector(changeSections))
        wire(interval, #selector(changeSections))
        wire(backToPanorama, #selector(closeDetail))
        wire(previousSection, #selector(moveToPreviousSection))
        wire(nextSection, #selector(moveToNextSection))
        wire(sendPoint, #selector(moveToMPR))
        wire(sendDetailPoint, #selector(moveToMPR))
        wire(settings, #selector(updateLayout))
        settings.setButtonType(.pushOnPushOff)
        settings.bezelStyle = .rounded
        settings.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        settings.imagePosition = .imageLeft
        settings.toolTip = String(localized: "Показать или скрыть параметры панорамы")
        wire(saveRuler, #selector(saveMeasurement))
        saveRuler.isHidden = true
        wire(detailRuler, #selector(toggleDetailRuler))
        wire(returnToCurrent, #selector(clearBookmarkArch))
        sendPoint.toolTip = String(localized: "Открыть выбранную точку дуги в трёх связанных плоскостях")
        sendDetailPoint.toolTip = sendPoint.toolTip
        backToPanorama.keyEquivalent = "\u{1b}"
        backToPanorama.keyEquivalentModifierMask = []
        showSections.state = .on
        showGuides.state = .on
        for slider in [position, slice, thickness, offset] { slider.isContinuous = true }
        position.setAccessibilityLabel(String(localized: "Положение на дуге"))
        slice.setAccessibilityLabel(String(localized: "Аксиальный срез для дуги"))
        thickness.setAccessibilityLabel(String(localized: "Толщина панорамного слоя"))
        offset.setAccessibilityLabel(String(localized: "Смещение панорамного слоя"))
        sectionWidth.setAccessibilityLabel(String(localized: "Ширина поперечного среза"))
        interval.setAccessibilityLabel(String(localized: "Шаг между поперечными срезами"))
        sectionWidth.addItems(withTitles: [String(localized: "20 мм"), String(localized: "30 мм"), String(localized: "40 мм")])
        interval.addItems(withTitles: [String(localized: "1 мм"), String(localized: "2 мм"), String(localized: "3 мм")])
        sectionWidth.selectItem(at: 1)
        interval.selectItem(at: 1)
        for (index, view) in ([preview, axial] + sections).enumerated() {
            view.inset = 15
            view.setAccessibilityLabel([String(localized: "Панорамная реконструкция"), String(localized: "Аксиальный срез с дугой"),
                                        String(localized: "Предыдущий поперечный срез"), String(localized: "Центральный поперечный срез"),
                                        String(localized: "Следующий поперечный срез")][index])
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
            view.unregisterDraggedTypes()
        }
        preview.onPoint = { [weak self] in self?.pickPanorama($0) }
        preview.onStep = { [weak self] in self?.stepArch($0) }
        axial.onPoint = { [weak self] in self?.pickAxial($0) }
        axial.onDragPoint = { [weak self] in self?.dragAxial($0) }
        axial.onReleasePoint = { [weak self] in self?.draggedNode = nil }
        axial.onStep = { [weak self] in self?.stepAxial($0) }
        preview.overlay = { [weak self] in self?.drawPanorama($0, $1) }
        axial.overlay = { [weak self] in self?.drawAxial($0, $1) }
        for (i, view) in sections.enumerated() {
            view.onStep = { [weak self] in self?.stepArch($0) }
            view.onPoint = { [weak self] in self?.pickCross(i, at: $0) }
            view.onDoubleClick = { [weak self] in self?.openDetail() }
            view.toolTip = String(localized: "Двойной щелчок — крупный просмотр")
            view.overlay = { [weak self, weak view] context, rect in
                guard let view else { return }
                self?.drawSection(context, rect, viewport: view.bounds, central: i == 1)
            }
            sectionTitles[i].alignment = .center
            sectionTitles[i].font = .monospacedDigitSystemFont(ofSize: 11, weight: i == 1 ? .semibold : .regular)
            sectionTitles[i].textColor = i == 1 ? .labelColor : .secondaryLabelColor
        }
        sections[1].frameColor = .controlAccentColor
        for field in [positionText, sliceText, thicknessText, offsetText] {
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let toolbar = row([jaw, edit, cancel, NSView(), sendPoint, settings])
        let detailToolbar = row([backToPanorama, caption(String(localized: "Поперечный срез")), sendDetailPoint,
                                 detailRuler, detailMeasurementLabel, saveRuler, NSView(), previousSection, nextSection])
        detailMeasurementLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        detailMeasurementLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailMeasurementLabel.lineBreakMode = .byTruncatingTail
        detailControls = detailToolbar
        detail.inset = 15
        detail.message = String(localized: "Строю поперечный срез…")
        detail.setAccessibilityLabel(String(localized: "Крупный поперечный срез"))
        detail.setContentHuggingPriority(.defaultLow, for: .vertical)
        detail.unregisterDraggedTypes()
        detail.onStep = { [weak self] in self?.stepSection($0) }
        detail.overlay = { [weak self] context, rect in
            guard let self else { return }
            self.drawSection(context, rect, viewport: self.detail.bounds, central: true)
            self.drawDetailRuler(context, rect: rect)
        }
        let location = row([positionText, position])
        let axialPane = column([axial, row([sliceText, slice])])
        let crossPanes = row(zip(sections, sectionTitles).map { column([$0.0, $0.1]) })
        crossPanes.distribution = .fillEqually
        crossPanes.alignment = .height
        let lower = row([axialPane, crossPanes])
        lower.alignment = .height
        lowerPane = lower
        let helpRow = row([help, undoPoint, returnToCurrent])
        setupGuide.font = .systemFont(ofSize: 13, weight: .medium)
        setupGuide.textColor = .secondaryLabelColor
        overviewControls = [toolbar, preview, helpRow]
        let stage = column([toolbar, setupGuide, preview, detailToolbar, detail, location, lower, helpRow])
        stage.spacing = 8
        addArrangedSubview(stage)
        stage.heightAnchor.constraint(equalTo: heightAnchor).isActive = true
        buildInspector()
        addArrangedSubview(inspector)
        let inspectorWidth: CGFloat = 208
        inspector.widthAnchor.constraint(equalToConstant: inspectorWidth).isActive = true
        fullStageWidth = stage.widthAnchor.constraint(equalTo: widthAnchor)
        reducedStageWidth = stage.widthAnchor.constraint(equalTo: widthAnchor, constant: -(inspectorWidth + spacing))
        let panelHeight = inspector.heightAnchor.constraint(equalTo: heightAnchor)
        panelHeight.priority = .defaultHigh
        panelHeight.isActive = true
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.lineBreakMode = .byTruncatingTail
        help.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 128).isActive = true
        lower.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        splitRatio = lower.heightAnchor.constraint(equalTo: preview.heightAnchor, multiplier: 0.68)
        splitRatio?.priority = .defaultHigh
        splitRatio?.isActive = true
        self.crossPanes = crossPanes
        overviewWidths = [
            axialPane.widthAnchor.constraint(equalTo: lower.widthAnchor, multiplier: 0.30),
            crossPanes.widthAnchor.constraint(equalTo: lower.widthAnchor, multiplier: 0.70, constant: -lower.spacing)
        ]
        setupWidth = axialPane.widthAnchor.constraint(equalTo: lower.widthAnchor)
        updateControls()
    }

    required init?(coder: NSCoder) { nil }

    private func buildInspector() {
        inspector.boxType = .custom
        inspector.borderColor = .separatorColor
        inspector.fillColor = .controlBackgroundColor
        inspector.cornerRadius = 8
        inspector.contentViewMargins = .zero

        let title = caption(String(localized: "Параметры панорамы"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let sectionHeading = caption(String(localized: "Поперечный срез"))
        sectionHeading.font = title.font
        let widthRow = row([caption(String(localized: "Ширина")), NSView(), sectionWidth])
        let intervalRow = row([caption(String(localized: "Шаг")), NSView(), interval])
        let flags = NSStackView(views: [showGuides, showSections])
        flags.orientation = .vertical
        flags.alignment = .leading
        flags.spacing = 4
        let panel = column([title, thicknessText, thickness, offsetText, offset, sectionHeading,
                            widthRow, intervalRow, flags, new, restore])
        panel.spacing = 6
        panel.setCustomSpacing(12, after: title)
        panel.setCustomSpacing(12, after: offset)
        panel.setCustomSpacing(12, after: intervalRow)
        panel.setCustomSpacing(10, after: flags)
        panel.translatesAutoresizingMaskIntoConstraints = false
        guard let content = inspector.contentView else { return }
        content.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            panel.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -12)
        ])
    }

    private func wire(_ control: NSControl, _ action: Selector) {
        control.target = self
        control.action = action
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        return stack
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    @discardableResult
    func load(_ volume: Volume, notes: StudyNotes, demoArches: StudyArches?, automatic: StudyArches?) -> Bool {
        closeDetail()
        renderTask?.cancel()
        self.volume = volume
        let known = notes.baseline ?? demoArches ?? StudyArches()
        let suggested = automatic ?? notes.automaticArches ?? StudyArches()
        let arches = [known.upper ?? suggested.upper, known.lower ?? suggested.lower]
        automaticOriginal = [known.upper == nil && suggested.upper != nil,
                             known.lower == nil && suggested.lower != nil]
        originals = arches.map { $0?.nodes ?? [] }
        initialZ = arches.map { $0?.axial ?? volume.depth / 2 }
        nodes = originals
        axialPositions = initialZ
        for (index, arch) in [notes.upper, notes.lower].enumerated() {
            if let arch {
                nodes[index] = arch.nodes
                axialPositions[index] = arch.axial
            }
        }
        archPositions = [0.5, 0.5]
        jaw.selectedSegment = nodes[0].isEmpty && !nodes[1].isEmpty ? 1 : 0
        bookmarkNodes = nil
        draft = nil
        draggedNode = nil
        slice.maxValue = Double(max(1, volume.depth - 1))
        thickness.doubleValue = 8
        offset.doubleValue = 0
        axial.sideLabels = volume.oriented ? Plane.axial.labels : []
        axial.aspect = volume.sliceSize(.axial).aspect
        preview.sideLabels = volume.oriented ? ["R", "L", "S", "I"] : []
        for view in sections {
            view.sideLabels = volume.oriented ? ["", "", "S", "I"] : []
        }
        detail.sideLabels = sections[1].sideLabels
        axial.image = nil
        rebuild()
        return hasArch
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value {
            schedule(panorama: true, axial: true, cross: true)
            if curve == nil { window?.makeFirstResponder(axial) }
        } else {
            closeDetail()
            renderTask?.cancel()
        }
    }

    func setDisplay(_ window: GrayWindow, zoom: Double) {
        if gray != window {
            gray = window
            schedule(panorama: true, axial: true, cross: true)
        }
        if preview.zoom != zoom {
            preview.setZoom(zoom, centeredAt: CGPoint(x: selectedX, y: selectedY))
        }
        for view in sections where view.zoom != zoom {
            view.setZoom(zoom, centeredAt: CGPoint(x: 0.5, y: selectedY))
        }
        if isDetailed, detail.zoom != zoom {
            detail.setZoom(zoom, centeredAt: CGPoint(x: 0.5, y: selectedY))
        }
    }

    var hasArch: Bool { curve != nil }

    var bookmark: SavedPanorama? {
        guard draft == nil, curve != nil else { return nil }
        return SavedPanorama(jaw: jawIndex, arch: SavedArch(nodes: currentNodes, axial: axialIndex), section: selected,
                             thickness: slab, offset: displacement, widthIndex: sectionWidth.indexOfSelectedItem,
                             intervalIndex: interval.indexOfSelectedItem, detailed: isDetailed,
                             showSections: showSections.state == .on, showGuides: showGuides.state == .on)
    }

    var exportFrame: ExportFrame? {
        guard !updateScheduled, draft == nil else { return nil }
        guard isDetailed else { return curve == nil ? axial.exportFrame : preview.exportFrame }
        guard var frame = detail.exportFrame else { return nil }
        if let first = rulerFirst, let second = rulerSecond, let distance = detailDistance {
            frame.ruler = ExportRuler(first: first, second: second, distance: distance)
        }
        return frame
    }

    var allowsArchEditing = true { didSet { updateControls() } }
    var isEditingArch: Bool { draft != nil }
    var canSaveDraft: Bool { draft != nil && curve != nil }

    @discardableResult
    func saveDraft() -> Bool {
        guard let draft, curve != nil,
              onSaveArch?(jawIndex, SavedArch(nodes: draft, axial: axialIndex)) == true else { return false }
        nodes[jawIndex] = draft
        bookmarkNodes = nil
        self.draft = nil
        updateControls()
        axial.needsDisplay = true
        return true
    }

    func discardDraft() { cancelEdit() }

    func restore(_ saved: SavedPanorama) {
        closeDetail()
        jaw.selectedSegment = saved.jaw
        bookmarkNodes = nodes[saved.jaw] == saved.arch.nodes ? nil : saved.arch.nodes
        axialPositions[saved.jaw] = saved.arch.axial
        thickness.doubleValue = saved.thickness
        offset.doubleValue = saved.offset
        sectionWidth.selectItem(at: saved.widthIndex)
        interval.selectItem(at: saved.intervalIndex)
        showSections.state = saved.showSections ? .on : .off
        showGuides.state = saved.showGuides ? .on : .off
        rebuild()
        setPosition(saved.section)
        if saved.detailed { openDetail() }
    }

    @objc private func moveToMPR() {
        guard let volume, let curve else { return }
        let point = curve.points[selected] + curve.normals[selected] * displacement
        onMoveToMPR?(SIMD3(point.x, point.y, Double(axialIndex) * volume.spacing[2]))
    }

    var mcpState: [String: Any] {
        var state: [String: Any] = [
            "view": (isDetailed ? MCPView.crossSection : .panorama).rawValue,
            "jaw": (jawIndex == 0 ? MCPJaw.upper : .lower).rawValue,
            "axial_slice": axialIndex + 1,
            "section_interval_mm": crossInterval
        ]
        if let curve {
            state["position_mm"] = Double(selected) * curve.step
            state["arch_length_mm"] = curve.length
        }
        return state
    }

    var currentMCPImage: CGImage? {
        if isDetailed { return needsCross ? nil : detail.image }
        return needsPanorama ? nil : preview.image
    }

    var detailWidthMM: Double { crossWidth }

    func setMCPDetail(_ open: Bool) {
        if open { openDetail() } else { closeDetail() }
    }

    func navigateMCP(_ args: ViewerCall.Arguments) throws {
        if let target = args.jaw {
            let index = target == .upper ? 0 : 1
            guard index != jawIndex else { return }
            guard draft == nil else { throw ViewerToolError(String(localized: "Сначала завершите редактирование дуги.")) }
            jaw.selectedSegment = index
            selectJaw()
            if !hasArch { closeDetail() }
        } else if let slice = args.slice {
            guard let volume, (1...volume.depth).contains(slice) else {
                throw ViewerToolError(String(localized: "Номер аксиального среза вне диапазона."))
            }
            setAxial(slice - 1)
        } else {
            guard let curve else { throw ViewerToolError(String(localized: "Сначала задайте дугу в панораме.")) }
            if let distance = args.position_mm {
                guard (0...curve.length).contains(distance) else {
                    throw ViewerToolError(String(localized: "Расстояние вне текущей дуги."))
                }
                setPosition(Int((distance / curve.step).rounded()))
            } else if let steps = args.steps {
                setPosition(selected + steps * crossStep)
            }
        }
    }

    private func openDetail() {
        guard let volume, curve != nil, !isDetailed else { return }
        isDetailed = true
        detail.aspect = crossWidth / volume.physicalHeight
        updateLayout()
        layoutSubtreeIfNeeded()
        detail.setZoom(preview.zoom, centeredAt: CGPoint(x: 0.5, y: selectedY))
        updateLabels()
        schedule(cross: true)
        window?.makeFirstResponder(detail)
    }

    @objc private func closeDetail() {
        guard isDetailed else { return }
        isDetailed = false
        detailRuler.state = .off
        toggleDetailRuler()
        detail.image = nil
        updateLayout()
        if active, !isHidden {
            layoutSubtreeIfNeeded()
            revealSelection()
            window?.makeFirstResponder(preview)
        }
    }

    @objc private func toggleDetailRuler() {
        let enabled = detailRuler.state == .on
        detail.resetsPanOnDoubleClick = !enabled
        detail.onPoint = enabled ? { [weak self] point in self?.pickDetailRuler(point) } : nil
        clearDetailMeasurement()
        if isDetailed { window?.makeFirstResponder(detail) }
    }

    var savedRuler: SavedRuler? {
        guard isDetailed, let first = rulerFirst, let second = rulerSecond else { return nil }
        return .section(first: first, second: second)
    }

    func restoreRuler(_ saved: SavedRuler) {
        guard isDetailed, case .section(let first, let second) = saved else { return }
        detailRuler.state = .on
        toggleDetailRuler()
        rulerFirst = first
        rulerSecond = second
        updateRulerDistance()
    }

    @objc private func saveMeasurement() { onSaveMeasurement?() }

    private func clearDetailMeasurement() {
        saveRuler.isHidden = true
        rulerFirst = nil
        rulerSecond = nil
        detailMeasurementLabel.stringValue = detailRuler.state == .on ?
            String(localized: "Укажите две точки") : ""
        detail.needsDisplay = true
    }

    private func pickDetailRuler(_ point: CGPoint) {
        guard isDetailed, !needsCross, detail.image != nil, let volume, let curve else { return }
        let location = SIMD2(Double(point.x), Double(point.y))
        let distance = displacement + (location.x - 0.5) * crossWidth
        let xy = curve.points[selected] + curve.normals[selected] * distance
        let z = ((1 - location.y) * Double(volume.depth) - 0.5) * volume.spacing[2]
        guard volume.containsMPRPoint(SIMD3(xy.x, xy.y, z)) else { return }
        if rulerFirst == nil || rulerSecond != nil {
            rulerFirst = location
            rulerSecond = nil
            saveRuler.isHidden = true
            detailMeasurementLabel.stringValue = String(localized: "Укажите вторую точку")
        } else {
            rulerSecond = location
            updateRulerDistance()
        }
        detail.needsDisplay = true
    }

    private func updateRulerDistance() {
        if let distance = detailDistance {
            detailMeasurementLabel.stringValue = String(localized: "Расстояние  \(mm(distance)) мм")
            saveRuler.isHidden = false
            detail.needsDisplay = true
        }
    }

    private var detailDistance: Double? {
        guard let volume, let first = rulerFirst, let second = rulerSecond else { return nil }
        return PlanarDistance.millimeters(from: first, to: second, extent: SIMD2(crossWidth, volume.physicalHeight))
    }

    private func drawDetailRuler(_ context: CGContext, rect: CGRect) {
        guard let first = rulerFirst else { return }
        func display(_ unit: SIMD2<Double>) -> CGPoint {
            CGPoint(x: rect.minX + unit.x * rect.width, y: rect.maxY - unit.y * rect.height)
        }
        RulerOverlay.draw(in: context, first: display(first), second: rulerSecond.map(display),
                          distance: detailDistance, viewport: rect.intersection(detail.bounds))
    }

    private var selectedX: Double {
        guard let curve else { return 0.5 }
        return (Double(selected) + 0.5) / Double(curve.points.count)
    }

    private var selectedY: Double {
        guard let volume else { return 0.5 }
        return 1 - (Double(axialIndex) + 0.5) / Double(volume.depth)
    }

    private func revealSelection() {
        if isDetailed { detail.reveal(CGPoint(x: 0.5, y: selectedY)) }
        preview.reveal(CGPoint(x: selectedX, y: selectedY))
        for view in sections { view.reveal(CGPoint(x: 0.5, y: selectedY)) }
    }

    @objc private func selectJaw() {
        bookmarkNodes = nil
        draft = nil
        draggedNode = nil
        rebuild()
    }

    @objc private func toggleEdit() {
        guard allowsArchEditing else { return }
        if draft != nil, curve != nil {
            guard saveDraft() else { return }
        } else if draft == nil {
            draft = currentNodes
            if draft!.isEmpty { startNew(); return }
        }
        updateControls()
        axial.needsDisplay = true
    }

    @objc private func startNew() {
        guard allowsArchEditing else { return }
        draft = []
        draggedNode = nil
        rebuild()
    }

    @objc private func removeDraftPoint() {
        guard draft?.isEmpty == false else { return }
        draft?.removeLast()
        draggedNode = nil
        rebuild()
    }

    @objc private func cancelEdit() {
        draft = nil
        draggedNode = nil
        rebuild()
    }

    @objc private func restoreArch() {
        guard allowsArchEditing, let volume, onSaveArch?(jawIndex, nil) == true else { return }
        nodes[jawIndex] = originals[jawIndex]
        bookmarkNodes = nil
        axialPositions[jawIndex] = originals[jawIndex].isEmpty ? volume.depth / 2 : initialZ[jawIndex]
        archPositions[jawIndex] = 0.5
        offset.doubleValue = 0
        cancelEdit()
    }

    @objc private func clearBookmarkArch() {
        bookmarkNodes = nil
        rebuild()
    }

    private func rebuild() {
        guard let volume else { return }
        let activeNodes = SavedArch.orderedNodes(draft ?? currentNodes)
        crossCache.removeAll()
        curve = ArchCurve(nodes: activeNodes, resolution: volume.archResolution)
        if let curve {
            position.maxValue = Double(curve.points.count - 1)
            position.doubleValue = archPositions[jawIndex] * position.maxValue
            preview.aspect = curve.length / volume.physicalHeight
        } else {
            preview.image = nil
            preview.message = String(localized: "Постройте дугу на аксиальном срезе")
            preview.needsDisplay = true
        }
        slice.doubleValue = Double(axialIndex)
        revealSelection()
        updateControls()
        schedule(panorama: true, axial: true, cross: true)
    }

    private func updateControls() {
        let editing = draft != nil
        jaw.isEnabled = !editing
        edit.title = editing ? String(localized: "Готово") :
            (currentNodes.isEmpty ? String(localized: "Построить дугу") : String(localized: "Править дугу"))
        edit.isEnabled = allowsArchEditing && volume != nil && (!editing || curve != nil)
        cancel.isHidden = !editing
        new.isHidden = editing || currentNodes.isEmpty
        new.isEnabled = allowsArchEditing
        undoPoint.isHidden = !editing
        undoPoint.isEnabled = draft?.isEmpty == false
        restore.title = automaticOriginal[jawIndex] ? String(localized: "Вернуть автоматическую дугу") :
            String(localized: "Исходная дуга")
        restore.isEnabled = allowsArchEditing && !editing && (!originals[jawIndex].isEmpty || nodes[jawIndex] != originals[jawIndex])
        returnToCurrent.isHidden = bookmarkNodes == nil || editing
        sendPoint.isEnabled = curve != nil && !editing
        sendDetailPoint.isEnabled = sendPoint.isEnabled
        position.isEnabled = curve != nil
        if let draft {
            help.stringValue = String(localized: "Точек: \(draft.count) · Пройдите по центрам зубов от одного края дуги к другому. Минимум три.")
        } else if curve == nil {
            help.stringValue = String(localized: "Выберите челюсть, найдите срез с видимыми зубами и нажмите «Построить дугу».")
        } else if bookmarkNodes == nil && automaticOriginal[jawIndex] &&
                    nodes[jawIndex] == originals[jawIndex] {
            help.stringValue = String(localized: "Автоматическая дуга · Сверьте её с аксиальным срезом и при необходимости нажмите «Править дугу».")
        } else {
            help.stringValue = String(localized: "Щелчок по панораме выбирает участок · Двойной щелчок по поперечному срезу увеличивает его")
        }
        updateLabels()
        updateLayout()
    }

    @objc private func updateLayout() {
        let settingUp = volume != nil && (curve == nil || draft != nil)
        let hideLowerPane = isDetailed || (showSections.state == .off && !settingUp)
        for view in overviewControls { view.isHidden = isDetailed }
        setupGuide.isHidden = !settingUp || isDetailed || draft != nil
        preview.isHidden = settingUp || isDetailed
        crossPanes?.isHidden = settingUp
        if settingUp {
            NSLayoutConstraint.deactivate(overviewWidths)
            setupWidth?.isActive = true
        } else {
            setupWidth?.isActive = false
            NSLayoutConstraint.activate(overviewWidths)
        }
        detailControls?.isHidden = !isDetailed
        detail.isHidden = !isDetailed
        let showInspector = !isDetailed && settings.state == .on
        if showInspector {
            fullStageWidth?.isActive = false
            inspector.isHidden = false
            reducedStageWidth?.isActive = true
        } else {
            reducedStageWidth?.isActive = false
            inspector.isHidden = true
            fullStageWidth?.isActive = true
        }
        showSections.isEnabled = draft == nil
        if hideLowerPane {
            splitRatio?.isActive = false
            lowerPane?.isHidden = true
        } else {
            lowerPane?.isHidden = false
            splitRatio?.isActive = !settingUp
        }
        preview.needsDisplay = true
        for view in sections { view.needsDisplay = true }
    }

    private func updateLabels() {
        thicknessText.stringValue = slab == 0 ? String(localized: "Тонкий срез") : String(localized: "Слой \(mm(slab)) мм")
        offsetText.stringValue = String(localized: "Смещение \(mm(displacement)) мм")
        if let volume {
            sliceText.stringValue = String(localized: "Аксиальный \(axialIndex + 1)/\(volume.depth)")
            axial.setAccessibilityValue(sliceText.stringValue)
        }
        if let curve {
            let distance = mm(Double(selected) * curve.step)
            positionText.stringValue = String(localized: "По дуге \(distance) / \(mm(curve.length)) мм")
            preview.setAccessibilityValue(positionText.stringValue)
            if isDetailed {
                detail.setAccessibilityValue(positionText.stringValue)
                previousSection.isEnabled = selected > 0
                nextSection.isEnabled = selected < curve.points.count - 1
            }
        } else {
            positionText.stringValue = String(localized: "Положение на дуге")
            preview.setAccessibilityValue(preview.message)
        }
    }

    private func mm(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    @objc private func changeSlab() {
        if crossCacheOffset != displacement { clearDetailMeasurement() }
        updateLabels()
        schedule(panorama: true, cross: true)
    }

    @objc private func changeSections() {
        if crossCacheWidth != crossWidth { clearDetailMeasurement() }
        schedule(cross: true)
    }
    @objc private func moveOnArch() { setPosition(selected) }
    @objc private func moveAxial() { setAxial(Int(slice.doubleValue.rounded())) }

    private func stepArch(_ amount: Int) {
        guard let curve else { return }
        setPosition(selected + amount * max(1, Int((0.5 / curve.step).rounded())))
    }

    @objc private func moveToPreviousSection() { stepSection(-1) }
    @objc private func moveToNextSection() { stepSection(1) }

    private func stepSection(_ amount: Int) {
        guard isDetailed else { return }
        setPosition(selected + amount * crossStep)
    }

    private func stepAxial(_ amount: Int) { setAxial(axialIndex + amount) }

    private func setPosition(_ index: Int) {
        guard let curve else { return }
        let current = min(curve.points.count - 1, max(0, index))
        if isDetailed, archPositions[jawIndex] != Double(current) / position.maxValue {
            clearDetailMeasurement()
        }
        position.doubleValue = Double(current)
        archPositions[jawIndex] = Double(current) / position.maxValue
        revealSelection()
        updateLabels()
        schedule(cross: true)
    }

    private func setAxial(_ index: Int) {
        guard let volume else { return }
        axialPositions[jawIndex] = min(volume.depth - 1, max(0, index))
        slice.doubleValue = Double(axialIndex)
        revealSelection()
        updateLabels()
        schedule(axial: true)
    }

    private func pickPanorama(_ point: CGPoint) {
        guard let curve, let volume, !preview.isHidden, preview.image != nil else { return }
        setPosition(Int((point.x * Double(curve.points.count) - 0.5).rounded()))
        setAxial(Int(((1 - point.y) * Double(volume.depth) - 0.5).rounded()))
    }

    private func pickCross(_ index: Int, at point: CGPoint) {
        guard let volume, let frame = crossIndex(index) else { return }
        setPosition(frame)
        setAxial(Int(((1 - point.y) * Double(volume.depth) - 0.5).rounded()))
    }

    private func physicalPoint(_ point: CGPoint, in volume: Volume) -> SIMD2<Double> {
        let x = min(Double(volume.width - 1), max(0, point.x * Double(volume.width) - 0.5))
        let y = min(Double(volume.height - 1), max(0, point.y * Double(volume.height) - 0.5))
        return SIMD2(x * volume.spacing[0], y * volume.spacing[1])
    }

    private func pickAxial(_ point: CGPoint) {
        guard let volume else { return }
        let location = physicalPoint(point, in: volume)
        if var draft {
            let nearest = draft.indices.min { simd_distance(draft[$0], location) < simd_distance(draft[$1], location) }
            if let nearest, simd_distance(draft[nearest], location) <= 2 {
                draggedNode = nearest
            } else if draft.count < 40, draft.last.map({ simd_distance($0, location) >= 0.6 }) ?? true {
                draft.append(location)
                self.draft = draft
                draggedNode = draft.count - 1
                rebuild()
            }
        } else if let curve, let nearest = curve.points.indices.min(by: {
            simd_distance(curve.points[$0], location) < simd_distance(curve.points[$1], location)
        }) {
            setPosition(nearest)
        }
    }

    private func dragAxial(_ point: CGPoint) {
        guard let volume, let i = draggedNode, var draft else { return }
        let candidate = physicalPoint(point, in: volume)
        let neighbors = [i - 1, i + 1].filter { draft.indices.contains($0) }
        guard neighbors.allSatisfy({ simd_distance(draft[$0], candidate) >= 0.6 }) else { return }
        draft[i] = candidate
        self.draft = draft
        rebuild()
    }

    private func crossIndex(_ index: Int) -> Int? {
        guard let curve else { return nil }
        let frame = selected + (index - 1) * crossStep
        return curve.points.indices.contains(frame) ? frame : nil
    }

    private func schedule(panorama: Bool = false, axial: Bool = false, cross: Bool = false) {
        needsPanorama = needsPanorama || panorama
        needsAxial = needsAxial || axial
        needsCross = needsCross || cross
        guard active, !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in self?.render() }
    }

    private func render() {
        updateScheduled = false
        guard active, let volume else { return }
        if needsAxial {
            axial.image = volume.image(.axial, index: axialIndex, windowWidth: gray.width, center: gray.center)
        }
        if needsCross {
            if crossCacheDisplay != gray || crossCacheWidth != crossWidth || crossCacheOffset != displacement {
                crossCache.removeAll()
                crossCacheDisplay = gray
                crossCacheWidth = crossWidth
                crossCacheOffset = displacement
            }
            var nextCache: [Int: CGImage] = [:]
            for i in sections.indices {
                let view = sections[i]
                if let curve, let frame = crossIndex(i) {
                    let prefix = i == 1 ? String(localized: "Выбранный · ") : ""
                    let name = String(localized: "\(prefix)\(mm(Double(frame) * curve.step)) мм")
                    sectionTitles[i].stringValue = name
                    view.setAccessibilityValue(name)
                    view.aspect = crossWidth / volume.physicalHeight
                    view.image = crossCache[frame] ?? volume.crossImage(curve, at: frame, width: crossWidth,
                                                                         offset: displacement, window: gray)
                    nextCache[frame] = view.image
                } else {
                    sectionTitles[i].stringValue = "—"
                    view.message = "—"
                    view.image = nil
                    view.setAccessibilityValue(String(localized: "Нет среза"))
                }
            }
            crossCache = nextCache
            if isDetailed { detail.image = sections[1].image }
        }
        if needsPanorama {
            renderTask?.cancel()
            if let curve {
                let thickness = slab, offset = displacement, window = gray
                preview.message = String(localized: "Строю панораму…")
                preview.image = nil
                let task = Task.detached(priority: .userInitiated) {
                    volume.panoramicImage(curve, thickness: thickness, offset: offset, window: window)
                }
                renderTask = task
                Task { [weak self] in
                    let image = await task.value
                    guard !task.isCancelled, let self else { return }
                    self.preview.image = image
                }
            }
        }
        needsPanorama = false
        needsAxial = false
        needsCross = false
        preview.needsDisplay = true
        axial.needsDisplay = true
        for view in sections { view.needsDisplay = true }
    }

    private func drawPanorama(_ ctx: CGContext, _ rect: CGRect) {
        guard let curve, let volume else { return }
        drawRuler(ctx, rect, viewport: preview.bounds, span: curve.step * Double(curve.points.count))
        guard showGuides.state == .on else { return }
        for i in sections.indices {
            guard let frame = crossIndex(i) else { continue }
            let x = rect.minX + (Double(frame) + 0.5) / Double(curve.points.count) * rect.width
            drawLine(ctx, from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY),
                     color: i == 1 ? .systemYellow : .systemOrange.withAlphaComponent(0.55),
                     width: i == 1 ? 1.5 : 0.7)
        }
        let y = rect.minY + (Double(axialIndex) + 0.5) / Double(volume.depth) * rect.height
        drawLine(ctx, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y),
                 color: .systemCyan.withAlphaComponent(0.6), width: 0.7)
    }

    private func drawAxial(_ ctx: CGContext, _ rect: CGRect) {
        guard let volume else { return }
        func screen(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(x: rect.minX + (p.x / volume.spacing[0] + 0.5) / Double(volume.width) * rect.width,
                    y: rect.maxY - (p.y / volume.spacing[1] + 0.5) / Double(volume.height) * rect.height)
        }
        if let curve {
            ctx.setStrokeColor(NSColor.systemYellow.cgColor)
            ctx.setLineWidth(1.35)
            ctx.beginPath()
            ctx.move(to: screen(curve.points[0]))
            for point in curve.points.dropFirst() { ctx.addLine(to: screen(point)) }
            ctx.strokePath()
            let point = curve.points[selected] + curve.normals[selected] * displacement
            let span = curve.normals[selected] * (crossWidth / 2)
            drawLine(ctx, from: screen(point - span), to: screen(point + span), color: .systemCyan, width: 1.5)
        }
        for point in draft ?? [] {
            let center = screen(point)
            let handle = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.fillEllipse(in: handle)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(0.7)
            ctx.strokeEllipse(in: handle)
        }
    }

    private func drawSection(_ ctx: CGContext, _ rect: CGRect, viewport: CGRect, central: Bool) {
        guard let volume else { return }
        drawRuler(ctx, rect, viewport: viewport, span: crossWidth)
        guard showGuides.state == .on else { return }
        let y = rect.minY + (Double(axialIndex) + 0.5) / Double(volume.depth) * rect.height
        drawLine(ctx, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y),
                 color: .systemCyan.withAlphaComponent(0.65), width: 0.8)
        if central {
            drawLine(ctx, from: CGPoint(x: rect.midX, y: rect.minY), to: CGPoint(x: rect.midX, y: rect.maxY),
                     color: .systemYellow.withAlphaComponent(0.7), width: 0.8)
        }
    }

    private func drawRuler(_ ctx: CGContext, _ rect: CGRect, viewport: CGRect, span: Double) {
        let visible = rect.intersection(viewport)
        guard visible.height >= 25, visible.width >= 40,
              let millimeters = [10, 5, 2, 1].first(where: { rect.width * Double($0) / span < visible.width - 16 })
        else { return }
        let length = rect.width * Double(millimeters) / span
        let left = visible.minX + 7, y = visible.minY + 8
        let right = left + length
        let color = NSColor.white
        drawLine(ctx, from: CGPoint(x: left, y: y), to: CGPoint(x: right, y: y), color: color, width: 1.25)
        for x in [left, right] {
            drawLine(ctx, from: CGPoint(x: x, y: y - 3), to: CGPoint(x: x, y: y + 3), color: color, width: 1.25)
        }
        let text = NSAttributedString(string: String(localized: "\(millimeters) мм"), attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: color, .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ])
        text.draw(at: CGPoint(x: left, y: y + 3))
    }

    private func drawLine(_ ctx: CGContext, from: CGPoint, to: CGPoint, color: NSColor, width: CGFloat) {
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.beginPath()
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()
    }
}
