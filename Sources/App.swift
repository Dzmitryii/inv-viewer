import AppKit
import UniformTypeIdentifiers

@MainActor
final class SliceView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var exportFrame: ExportFrame? {
        image.map { ExportFrame(image: $0, aspect: aspect, labels: sideLabels) }
    }
    var aspect = 1.0
    var sideLabels = [String]()
    var message = String(localized: "Откройте снимок INV или DICOM")
    private(set) var zoom = 1.0
    var onStep: ((Int) -> Void)?
    var onPlane: ((Int) -> Void)?
    var onOpen: ((URL) -> Void)?
    var overlay: ((CGContext, CGRect) -> Void)?
    var onPoint: ((CGPoint) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragPoint: ((CGPoint) -> Void)?
    var onReleasePoint: (() -> Void)?
    var onGestureStart: ((CGPoint, NSEvent.ModifierFlags) -> Bool)?
    var onGestureMove: ((CGPoint) -> Void)?
    var onGestureEnd: (() -> Void)?
    var onAdjustDisplay: ((CGFloat, CGFloat) -> Void)?
    var resetsPanOnDoubleClick = true
    var inset: CGFloat = 28
    var frameColor: NSColor? { didSet { needsDisplay = true } }

    private var scrollRemainder: CGFloat = 0
    private var pan = CGPoint.zero
    private var pendingSelection: CGPoint?
    private var completedClick = false
    private var handlingGesture = false
    private var adjustingDisplay = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        wantsLayer = true
        layer?.cornerRadius = 6
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Срез КЛКТ"))
    }

    required init?(coder: NSCoder) { nil }

    private var imageRect: CGRect {
        let fitWidth = min(max(1, bounds.width - 2 * inset), max(1, bounds.height - 2 * inset) * aspect)
        let width = fitWidth * zoom
        let height = width / aspect
        return CGRect(x: bounds.midX - width / 2 + pan.x, y: bounds.midY - height / 2 + pan.y,
                      width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.intersection(bounds).fill()
        defer {
            if let frameColor {
                frameColor.setStroke()
                let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                path.lineWidth = 2
                path.stroke()
            }
        }
        guard let image, let context = NSGraphicsContext.current?.cgContext else {
            drawText(message, centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), size: 17)
            return
        }
        let rect = imageRect
        context.interpolationQuality = .none
        context.draw(image, in: rect)
        context.saveGState()
        context.clip(to: rect)
        overlay?(context, rect)
        context.restoreGState()
        if sideLabels.count == 4 {
            drawText(sideLabels[0], centeredAt: CGPoint(x: inset / 2, y: bounds.midY), size: 12)
            drawText(sideLabels[1], centeredAt: CGPoint(x: bounds.maxX - inset / 2, y: bounds.midY), size: 12)
            drawText(sideLabels[2], centeredAt: CGPoint(x: bounds.midX, y: bounds.maxY - inset / 2), size: 12)
            drawText(sideLabels[3], centeredAt: CGPoint(x: bounds.midX, y: inset / 2), size: 12)
        }
    }

    private func drawText(_ string: String, centeredAt point: CGPoint, size: CGFloat) {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.85)
        ])
        let measured = text.size()
        text.draw(at: CGPoint(x: point.x - measured.width / 2, y: point.y - measured.height / 2))
    }

    func resetPan() {
        pan = .zero
        needsDisplay = true
    }

    func setZoom(_ factor: Double, centeredAt point: CGPoint? = nil) {
        zoom = factor
        if factor > 1, let point {
            let rect = imageRect
            setPan(CGPoint(x: (0.5 - point.x) * rect.width, y: (point.y - 0.5) * rect.height))
        } else {
            resetPan()
        }
    }

    func reveal(_ point: CGPoint) {
        guard zoom > 1, !bounds.isEmpty else { return }
        let rect = imageRect
        let visible = bounds.insetBy(dx: inset, dy: inset)
        let x = rect.minX + point.x * rect.width
        let y = rect.maxY - point.y * rect.height
        let shiftX = min(visible.maxX, max(visible.minX, x)) - x
        let shiftY = min(visible.maxY, max(visible.minY, y)) - y
        setPan(CGPoint(x: pan.x + shiftX, y: pan.y + shiftY))
    }

    private func setPan(_ proposed: CGPoint) {
        let rect = imageRect
        let maxX = max(0, (rect.width - bounds.width + 2 * inset) / 2)
        let maxY = max(0, (rect.height - bounds.height + 2 * inset) / 2)
        pan.x = min(maxX, max(-maxX, proposed.x))
        pan.y = min(maxY, max(-maxY, proposed.y))
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard image != nil, event.momentumPhase == [] else { return }
        if event.phase == .began || event.phase == .ended || event.phase == .cancelled {
            scrollRemainder = 0
        }
        let delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            if delta * scrollRemainder < 0 { scrollRemainder = 0 }
            scrollRemainder -= delta
            let steps = Int(scrollRemainder / 8)
            if steps != 0 {
                scrollRemainder -= CGFloat(steps * 8)
                onStep?(steps)
            }
        } else if delta != 0 {
            onStep?(delta < 0 ? 1 : -1)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: onStep?(-1)
        case 124, 125: onStep?(1)
        default:
            if let text = event.charactersIgnoringModifiers, let plane = Int(text), (1...3).contains(plane) {
                onPlane?(plane - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pendingSelection = nil
        handlingGesture = false
        let point = convert(event.locationInWindow, from: nil)
        adjustingDisplay = image != nil && imageRect.contains(point) &&
            event.modifierFlags.contains(.option) && onAdjustDisplay != nil
        if adjustingDisplay { completedClick = false; return }
        if image != nil, imageRect.contains(point), !event.modifierFlags.contains(.option),
           onGestureStart?(normalized(point), event.modifierFlags) == true {
            handlingGesture = true
            completedClick = false
            return
        }
        let opensSelection = event.clickCount == 2 && completedClick
        completedClick = false
        if opensSelection, let onDoubleClick {
            onDoubleClick()
            return
        }
        if resetsPanOnDoubleClick, event.clickCount == 2, zoom > 1 { resetPan(); return }
        guard image != nil, imageRect.contains(point), !event.modifierFlags.contains(.option) else { return }
        if onDragPoint != nil {
            onPoint?(normalized(point))
        } else if onPoint != nil {
            pendingSelection = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if adjustingDisplay { onAdjustDisplay?(event.deltaX, event.deltaY); return }
        let point = convert(event.locationInWindow, from: nil)
        if handlingGesture {
            onGestureMove?(normalized(point))
            return
        }
        if let start = pendingSelection {
            guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
            pendingSelection = nil
        }
        if image != nil, let onDragPoint {
            onDragPoint(normalized(point))
            return
        }
        guard image != nil, zoom > 1 else { return }
        setPan(CGPoint(x: pan.x + event.deltaX, y: pan.y - event.deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        if adjustingDisplay { adjustingDisplay = false; return }
        if handlingGesture {
            handlingGesture = false
            onGestureEnd?()
            return
        }
        if let point = pendingSelection, image != nil {
            onPoint?(normalized(point))
            completedClick = true
        }
        pendingSelection = nil
        onReleasePoint?()
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (rect.maxY - point.y) / rect.height)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        studyURL(from: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = studyURL(from: sender) else { return false }
        onOpen?(url)
        return true
    }
}

@MainActor
final class Viewer: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
    private let view = SliceView(frame: .zero)
    private let panorama = Panorama(frame: .zero)
    private let mpr = MPRView(frame: .zero)
    private let welcome = WelcomeView(frame: .zero)
    private let mode = NSSegmentedControl(labels: [String(localized: "Срезы"), String(localized: "Панорама"), "MPR"],
                                          trackingMode: .selectOne, target: nil, action: nil)
    private let volumeButton = NSButton(title: "3D", target: nil, action: nil)
    private let bookmarks = NSPopUpButton(frame: .zero, pullsDown: true)
    private let navigation = NSStackView()
    private let fileLabel = NSTextField(labelWithString: String(localized: "Файл не открыт"))
    private let frameLabel = NSTextField(labelWithString: String(localized: "Срез —"))
    private let status = NSTextField(labelWithString: String(localized: "Перетащите снимок INV или DICOM в окно"))
    private let openButton = NSButton()
    private let planes = NSSegmentedControl(labels: [String(localized: "Аксиальная"), String(localized: "Корональная"), String(localized: "Сагиттальная")],
                                           trackingMode: .selectOne, target: nil, action: nil)
    private let index = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let level = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let width = NSSlider(value: 1, minValue: 1, maxValue: 2, target: nil, action: nil)
    private let zoom = NSSlider(value: 1, minValue: 1, maxValue: 4, target: nil, action: nil)
    private let reset = NSButton()
    private let levelInput = NSTextField()
    private let widthInput = NSTextField()
    private let presets = ImagePresets(frame: .zero, pullsDown: true)
    private var displayCeiling = 1.0
    private let spinner = NSProgressIndicator()
    private var documentChrome = [NSView]()
    private var volume: Volume?
    private var lastOpenedFolder: URL?
    private var busy = false
    private var loadID = UUID()
    private var readTask: Task<Result<(Volume, ScanLink?), Error>, Never>?
    private var archTask: Task<StudyArches, Never>?
    private let cancelLoadButton = NSButton(title: String(localized: "Отменить загрузку"), target: nil, action: nil)
    private var statusBeforeLoad = ""
    private var plane = Plane.axial
    private var indices = [0, 0, 0]
    private var renderScheduled = false
    private var mcpListener: DispatchSourceRead?
    private let mcpPreference = "allowLocalMCP"
    private var mcpItem: NSMenuItem?
    private var notes = StudyNotes()
    private var studyStore: StudyStore?
    private var openedDemo = false
    private var switchingLanguage = false
    private var activeBookmark: UUID?
    private let annotationButton = NSButton(title: String(localized: "Заметка"), target: nil, action: nil)
    private var patientsWindow: PatientsWindow?
    private var backupController: BackupController?
    private let recentMenu = NSMenu()
    private var recentItems: [ScanLink] = []
    private var exportItem: NSMenuItem?
    private var volumeItem: NSMenuItem?
    private var volumeWindow: VolumeWindow?
    private var mcpVolumeActive = false
    private var mcpImage: (id: UUID, location: StudyBookmark.Location)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        refreshRecentMenu()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--language-relaunch") {
            // The previous instance releases the local MCP socket after the new instance launches.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restoreLocalMCP() }
        } else {
            restoreLocalMCP()
        }
        if CommandLine.arguments.contains("--open-demo") { openDemo() }
    }

    private func restoreLocalMCP() {
        guard mcpListener == nil, UserDefaults.standard.bool(forKey: mcpPreference) else { return }
        do { try startLocalMCP() } catch { NSLog("%@", error.localizedDescription) }
        mcpItem?.state = mcpListener == nil ? .off : .on
    }

    func applicationWillTerminate(_ notification: Notification) {
        readTask?.cancel()
        archTask?.cancel()
        rememberView()
        mcpListener?.cancel()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { load(url) }
    }

    func windowWillClose(_ notification: Notification) {
        cancelLoading()
        rememberView()
        volumeWindow?.close()
    }

    func windowDidBecomeKey(_ notification: Notification) { mcpVolumeActive = false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard panorama.isEditingArch else { return true }
        confirmDraft { [weak self] close in
            if close {
                // Close after AppKit has detached the confirmation sheet.
                DispatchQueue.main.async { self?.window.close() }
            }
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard panorama.isEditingArch else { return .terminateNow }
        guard window.attachedSheet == nil else { return .terminateCancel }
        confirmDraft { close in sender.reply(toApplicationShouldTerminate: close) }
        return .terminateLater
    }

    private func confirmDraft(_ completion: @escaping (Bool) -> Void) {
        guard window.attachedSheet == nil else { completion(false); return }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = String(localized: "Сохранить изменения дуги?")
        alert.informativeText = panorama.canSaveDraft ?
            String(localized: "Изменённая дуга ещё не сохранена.") :
            String(localized: "Дуга не завершена. Вернитесь к редактированию или закройте без сохранения.")
        alert.addButton(withTitle: String(localized: "Сохранить")).isEnabled = panorama.canSaveDraft
        alert.addButton(withTitle: String(localized: "Не сохранять"))
        alert.addButton(withTitle: String(localized: "Отмена")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { completion(false); return }
            if response == .alertFirstButtonReturn { completion(panorama.saveDraft()) }
            else if response == .alertSecondButtonReturn { panorama.discardDraft(); completion(true) }
            else { completion(false) }
        }
    }

    private func buildMenu() {
        let root = NSMenu()
        let appItem = NSMenuItem()
        root.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "Закрыть INV Viewer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        root.addItem(fileItem)
        let fileMenu = NSMenu(title: String(localized: "Файл"))
        let openItem = fileMenu.addItem(withTitle: String(localized: "Открыть снимок…"), action: #selector(chooseFile), keyEquivalent: "o")
        openItem.target = self
        let patientsItem = fileMenu.addItem(withTitle: String(localized: "Пациенты"), action: #selector(showPatients), keyEquivalent: "l")
        patientsItem.target = self
        patientsItem.keyEquivalentModifierMask = [.command, .shift]
        let recent = NSMenuItem(title: String(localized: "Недавние снимки"), action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        fileMenu.addItem(recent)
        let export = fileMenu.addItem(withTitle: String(localized: "Экспортировать PNG…"), action: #selector(exportPNG), keyEquivalent: "e")
        export.target = self
        export.keyEquivalentModifierMask = [.command, .shift]
        exportItem = export
        fileMenu.addItem(withTitle: String(localized: "Открыть демо"), action: #selector(openDemo), keyEquivalent: "").target = self
        let bookmarkItem = fileMenu.addItem(withTitle: String(localized: "Добавить отметку…"), action: #selector(addBookmark),
                                            keyEquivalent: "d")
        bookmarkItem.target = self
        fileMenu.addItem(withTitle: String(localized: "Сохранить измерение…"), action: #selector(saveMeasurement), keyEquivalent: "").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Создать резервную копию…"), action: #selector(exportBackup), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: String(localized: "Восстановить резервную копию…"), action: #selector(importBackup), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: String(localized: "Закрыть окно"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: String(localized: "Отменить загрузку"), action: #selector(cancelLoading), keyEquivalent: ".").target = self
        let editing = NSMenuItem()
        editing.submenu = EditingMenu.make()
        root.addItem(editing)
        let viewsItem = NSMenuItem()
        root.addItem(viewsItem)
        let views = NSMenu(title: String(localized: "Вид"))
        for (index, title) in [String(localized: "Срезы"), String(localized: "Панорама"),
                               String(localized: "Три плоскости (MPR)")].enumerated() {
            let item = views.addItem(withTitle: title, action: #selector(selectViewingMode(_:)), keyEquivalent: String(index + 1))
            item.target = self
            item.tag = index
        }
        let volumeItem = views.addItem(withTitle: String(localized: "Объёмный 3D"), action: #selector(showVolume), keyEquivalent: "4")
        volumeItem.target = self
        self.volumeItem = volumeItem
        viewsItem.submenu = views
        let toolsItem = NSMenuItem()
        root.addItem(toolsItem)
        let toolsMenu = NSMenu(title: String(localized: "Инструменты"))
        let mcp = toolsMenu.addItem(withTitle: String(localized: "Локальный MCP"), action: #selector(toggleLocalMCP), keyEquivalent: "")
        mcp.target = self
        mcpItem = mcp
        toolsItem.submenu = toolsMenu
        let languageItem = NSMenuItem()
        root.addItem(languageItem)
        languageItem.submenu = makeLanguageMenu()
        NSApp.mainMenu = root
    }

    private func makeLanguageMenu() -> NSMenu {
        let languages = NSMenu(title: "Язык / Language")
        let russian = languages.addItem(withTitle: "Русский", action: #selector(useRussian), keyEquivalent: "")
        let english = languages.addItem(withTitle: "English", action: #selector(useEnglish), keyEquivalent: "")
        russian.target = self
        english.target = self
        let current = Bundle.main.preferredLocalizations.first
        russian.state = current == "ru" ? .on : .off
        english.state = current == "en" ? .on : .off
        return languages
    }

    private func startLocalMCP() throws {
        mcpListener = try LocalBridge.listen { [weak self] data in
            guard let self, mcpListener != nil else { return .immediate(Data()) }
            return handleMCP(data)
        }
    }

    @objc private func toggleLocalMCP() {
        if let listener = mcpListener {
            mcpListener = nil
            listener.cancel()
            UserDefaults.standard.set(false, forKey: mcpPreference)
            mcpItem?.state = .off
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Включить локальный MCP?")
        alert.informativeText = String(localized: "Процессы вашего пользователя смогут управлять открытым снимком и получать его изображения через локальный сокет. Включайте для клиента, которому доверяете.")
        alert.addButton(withTitle: String(localized: "Включить"))
        alert.addButton(withTitle: String(localized: "Отмена"))
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn, mcpListener == nil else { return }
            do {
                try startLocalMCP()
                UserDefaults.standard.set(true, forKey: mcpPreference)
                mcpItem?.state = .on
            } catch {
                showAlert(String(localized: "Не удалось запустить локальный MCP"), error.localizedDescription)
            }
        }
    }

    private func buildWindow() {
        window.title = String(localized: "Просмотр КЛКТ · INV Viewer")
        window.delegate = self
        window.minSize = NSSize(width: 730, height: 480)
        window.isReleasedWhenClosed = false

        openButton.title = String(localized: "Открыть снимок…")
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(chooseFile)
        openButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        openButton.imagePosition = .imageLeft
        welcome.onOpen = { [weak self] in self?.chooseFile() }
        welcome.onCancel = { [weak self] in self?.cancelLoading() }
        let patients = NSButton(title: String(localized: "Пациенты"), target: self, action: #selector(showPatients))
        patients.bezelStyle = .rounded
        patients.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        patients.imagePosition = .imageLeft
        welcome.onPatients = { [weak self] in self?.showPatients() }
        welcome.onDemo = { [weak self] in self?.openDemo() }
        welcome.setLanguageMenu(makeLanguageMenu())
        welcome.onResume = { [weak self] in self?.resumeLastScan() }
        welcome.onDrop = { [weak self] in self?.load($0) }
        reset.title = String(localized: "Сбросить")
        reset.bezelStyle = .rounded
        reset.target = self
        reset.action = #selector(resetControls)
        mode.target = self
        mode.action = #selector(changeMode)
        mode.setToolTip(String(localized: "Три плоскости (MPR)"), forSegment: 2)
        mode.setAccessibilityLabel(String(localized: "Режим просмотра"))
        mode.selectedSegment = 0

        for control in [planes, index, level, width, zoom] {
            control.target = self
        }
        planes.action = #selector(changePlane)
        index.action = #selector(changeIndex)
        level.action = #selector(changeDisplay)
        width.action = #selector(changeDisplay)
        zoom.action = #selector(changeZoom)
        index.isContinuous = true
        level.isContinuous = true
        width.isContinuous = true
        zoom.isContinuous = true
        configureDisplayField(levelInput, label: String(localized: "Число яркости"), minimum: 0)
        configureDisplayField(widthInput, label: String(localized: "Число ширины окна"), minimum: 1)
        presets.hostWindow = window
        presets.current = { [weak self] in self?.currentGray }
        presets.apply = { [weak self] in self?.setGray($0) }
        index.setAccessibilityLabel(String(localized: "Номер среза"))
        level.setAccessibilityLabel(String(localized: "Уровень яркости"))
        width.setAccessibilityLabel(String(localized: "Ширина окна контраста"))
        zoom.setAccessibilityLabel(String(localized: "Масштаб"))
        planes.setAccessibilityLabel(String(localized: "Плоскость среза"))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 18).isActive = true
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        frameLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        bookmarks.setAccessibilityLabel(String(localized: "Отметки исследования"))
        bookmarks.setContentHuggingPriority(.required, for: .horizontal)
        refreshBookmarkMenu()
        annotationButton.bezelStyle = .rounded
        annotationButton.target = self
        annotationButton.action = #selector(showAnnotation)
        annotationButton.isHidden = true
        volumeButton.bezelStyle = .rounded
        volumeButton.target = self
        volumeButton.action = #selector(showVolume)
        volumeButton.setAccessibilityLabel(String(localized: "Объёмный 3D"))
        volumeButton.toolTip = String(localized: "Объёмный 3D")
        cancelLoadButton.target = self
        cancelLoadButton.action = #selector(cancelLoading)
        cancelLoadButton.bezelStyle = .rounded
        let top = row([openButton, patients, fileLabel, spinner, cancelLoadButton, NSView(), mode, volumeButton, annotationButton, bookmarks])
        let rule = NSBox()
        rule.boxType = .separator
        navigation.orientation = .horizontal
        navigation.alignment = .centerY
        navigation.spacing = 10
        navigation.addArrangedSubview(planes)
        navigation.addArrangedSubview(frameLabel)
        navigation.addArrangedSubview(index)
        let controls = row([label(String(localized: "Яркость")), level, levelInput, label(String(localized: "Контраст")),
                            width, widthInput, label(String(localized: "Масштаб")), zoom, presets, reset])
        level.widthAnchor.constraint(equalTo: width.widthAnchor).isActive = true
        width.widthAnchor.constraint(equalTo: zoom.widthAnchor).isActive = true
        view.onOpen = { [weak self] in self?.load($0) }
        view.onStep = { [weak self] in self?.step($0) }
        let adjust: (CGFloat, CGFloat) -> Void = { [weak self] in self?.adjustDisplay(x: $0, y: $1) }
        view.onAdjustDisplay = adjust
        mpr.onAdjustDisplay = adjust
        panorama.onAdjustDisplay = adjust
        view.onPlane = { [weak self] in self?.setPlane($0) }
        mpr.onSaveMeasurement = { [weak self] in self?.saveMeasurement() }
        panorama.onSaveMeasurement = { [weak self] in self?.saveMeasurement() }
        mpr.onOpen = { [weak self] in self?.load($0) }
        panorama.onSaveArch = { [weak self] jaw, arch in
            guard let self else { return false }
            var updated = notes
            if jaw == 0 { updated.upper = arch } else { updated.lower = arch }
            return saveNotes(updated)
        }
        panorama.onMoveToMPR = { [weak self] point in
            guard let self, let volume, !busy else { return }
            guard volume.containsMPRPoint(point) else {
                showAlert(String(localized: "Точка за пределами снимка"), String(localized: "Уменьшите смещение слоя в панораме и повторите."))
                return
            }
            mpr.goTo(point)
            mode.selectedSegment = 2
            changeMode()
        }
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 290).isActive = true

        let content = NSView()
        panorama.isHidden = true
        mpr.isHidden = true
        documentChrome = [top, rule, controls, status]
        let arranged = [top, rule, welcome, view, navigation, panorama, mpr, controls, status]
        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        for item in arranged {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.contentView = content
        updatePlane()
        changeMode()
        updateEnabled()
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        return row
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 12)
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }

    @objc private func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Открыть снимок КЛКТ")
        panel.message = String(localized: "Выберите снимок INV, файл DICOM или папку экспорта КТ.")
        panel.directoryURL = lastOpenedFolder ?? Bundle.main.bundleURL.deletingLastPathComponent()
        panel.allowedContentTypes = StudyFile.contentTypes
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.load(url) }
        }
    }

    @objc private func useRussian() { switchLanguage(to: "ru") }
    @objc private func useEnglish() { switchLanguage(to: "en") }

    private func switchLanguage(to language: String) {
        guard !switchingLanguage, !busy, NSApp.modalWindow == nil,
              NSApp.windows.allSatisfy({ $0.attachedSheet == nil }) else { return }
        guard !panorama.isEditingArch else {
            showAlert(String(localized: "Сначала завершите правку дуги"),
                      String(localized: "Нажмите «Готово» или «Отмена» в панораме."))
            return
        }
        let preferences = UserDefaults.standard
        let key = "AppleLanguages"
        let previous = Bundle.main.bundleIdentifier.flatMap { preferences.persistentDomain(forName: $0)?[key] }
        let current = Bundle.main.preferredLocalizations.first
        preferences.set([language], forKey: key)
        if current == language { return }
        _ = preferences.synchronize()
        rememberView()
        switchingLanguage = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-AppleLanguages", "(\(language))", "--language-relaunch"] + (openedDemo ? ["--open-demo"] : [])
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] application, error in
            Task { @MainActor in
                guard let self else { return }
                self.switchingLanguage = false
                if application != nil, error == nil {
                    NSApp.terminate(nil)
                } else {
                    UserDefaults.standard.set(previous, forKey: key)
                    self.showAlert(String(localized: "Не удалось сменить язык"), error?.localizedDescription ?? "")
                }
            }
        }
    }

    @objc private func openDemo() {
        guard let sample = Bundle.main.url(forResource: "DemoStudy", withExtension: "inv") else {
            showAlert(String(localized: "Демо недоступно"), String(localized: "Пересоберите приложение из полного проекта."))
            return
        }
        load(sample, demonstration: true)
    }

    @objc private func showPatients() {
        guard let root = StudyLibrary.storageRoot else { return }
        if patientsWindow == nil {
            let controller = PatientsWindow(root: root)
            controller.onOpen = { [weak self] patient, study in
                self?.openLink(study.link, libraryTitle: patient.name + " · " + study.title)
            }
            patientsWindow = controller
        }
        patientsWindow?.show()
    }

    private func backups() -> BackupController? {
        guard !busy, window.attachedSheet == nil, !panorama.isEditingArch,
              let root = StudyLibrary.storageRoot else {
            if panorama.isEditingArch {
                showAlert(String(localized: "Сначала завершите правку дуги"), String(localized: "Нажмите «Готово» или «Отмена» в панораме."))
            }
            return nil
        }
        rememberView()
        if backupController == nil {
            let controller = BackupController(root: root, window: window)
            controller.onImport = { [weak self] in
                guard let self else { return }
                patientsWindow?.show()
                if let volume {
                    let restored = readStudyNotes(for: volume)
                    notes = restored.notes
                    studyStore = restored.store
                    refreshBookmarkMenu()
                }
            }
            backupController = controller
        }
        return backupController
    }

    @objc private func exportBackup() { backups()?.exportBackup() }
    @objc private func importBackup() { backups()?.importBackup() }

    private var recentStore: LocalDocument<RecentScans>? {
        StudyLibrary.storageRoot.map { RecentScans.store(at: $0) }
    }

    private func refreshRecentMenu() {
        recentMenu.removeAllItems()
        defer { welcome.hasRecentScan = !recentItems.isEmpty }
        do {
            recentItems = try recentStore?.read(default: RecentScans(), valid: { $0.valid }).links ?? []
        } catch {
            recentItems = []
            recentMenu.addItem(withTitle: String(localized: "История недоступна"), action: nil, keyEquivalent: "")
            return
        }
        if recentItems.isEmpty {
            recentMenu.addItem(withTitle: String(localized: "Нет недавних снимков"), action: nil, keyEquivalent: "")
            return
        }
        for (index, link) in recentItems.enumerated() {
            let item = recentMenu.addItem(withTitle: link.displayName, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
        }
        recentMenu.addItem(.separator())
        recentMenu.addItem(withTitle: String(localized: "Очистить историю"), action: #selector(clearRecent), keyEquivalent: "").target = self
    }

    private func resumeLastScan() {
        if let latest = recentItems.first { openLink(latest) }
    }

    @objc private func openRecent(_ item: NSMenuItem) {
        guard recentItems.indices.contains(item.tag) else { return }
        openLink(recentItems[item.tag])
    }

    @objc private func clearRecent() {
        updateRecent { $0.links.removeAll() }
    }

    private func updateRecent(_ edit: (inout RecentScans) -> Void) {
        guard let store = recentStore else { return }
        do {
            let previous = try store.read(default: RecentScans(), valid: { $0.valid })
            var updated = previous
            edit(&updated)
            try store.write(updated, replacing: previous, default: RecentScans(), valid: { $0.valid })
        } catch {
            status.stringValue += String(localized: " · История не сохранена")
        }
        refreshRecentMenu()
    }

    private func openLink(_ link: ScanLink, libraryTitle: String? = nil) {
        guard !busy else { return }
        window.makeKeyAndOrderFront(nil)
        do {
            let url = try link.resolve()
            load(url, expected: link.fingerprint, libraryTitle: libraryTitle, dicomSeries: link.dicomSeries)
        } catch {
            showAlert(String(localized: "Снимок недоступен"), missingFileHelp(libraryTitle != nil))
        }
    }

    private func missingFileHelp(_ fromLibrary: Bool) -> String {
        fromLibrary ? String(localized: "Проверьте подключение диска или перепривяжите снимок в карточке пациента.") :
            String(localized: "Проверьте подключение диска или выберите снимок заново через «Открыть снимок…».")
    }

    private func load(_ url: URL, demonstration: Bool = false, expected: String? = nil,
                      libraryTitle: String? = nil, dicomSeries: String? = nil) {
        let fromLibrary = libraryTitle != nil
        guard !busy, StudyFile.accepts(url) else { return }
        guard !panorama.isEditingArch else {
            showAlert(String(localized: "Сначала завершите правку дуги"),
                      String(localized: "Нажмите «Готово» или «Отмена» в панораме."))
            return
        }
        rememberView()
        busy = true
        updateEnabled()
        spinner.startAnimation(nil)
        let previousStatus = status.stringValue
        statusBeforeLoad = previousStatus
        let job = UUID()
        loadID = job
        status.stringValue = String(localized: "Загружаю объём снимка…")
        view.message = String(localized: "Читаю снимок…")
        view.needsDisplay = true
        Task { [self] in
            guard loadID == job else { return }
            let work = Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return Result {
                    let loaded = try Volume.read(url, dicomSeries: dicomSeries)
                    try Task.checkCancellation()
                    guard let fingerprint = loaded.fingerprint else { throw StudyLibraryError.invalid }
                    if let expected, !loaded.matchesFingerprint(expected) { throw StudyLibraryError.differentScan }
                    let link = demonstration || fromLibrary ? nil : try? ScanLink.make(url, fingerprint: fingerprint, dicomSeries: loaded.dicomSeries, seriesNumber: loaded.dicomSeriesNumber)
                    return (loaded, link)
                }
            }
            readTask = work
            let result = await work.value
            guard loadID == job else { return }
            readTask = nil
            switch result {
            case .success((let loaded, let link)):
                let study = readStudyNotes(for: loaded)
                var loadedNotes = study.notes
                var lastView = loadedNotes.lastView
                var suggestion: StudyArches?
                if !demonstration && loadedNotes.needsAutomaticArches {
                    status.stringValue = String(localized: "Подбираю дугу по снимку…")
                    let estimate = Task.detached(priority: .userInitiated) {
                        AutomaticArches.estimate(in: loaded)
                    }
                    archTask = estimate
                    let result = await estimate.value
                    guard loadID == job else { return }
                    archTask = nil
                    if result.upper != nil || result.lower != nil || loadedNotes.automaticArches != nil {
                        suggestion = result
                        let updated = loadedNotes.withAutomaticArches(result)
                        lastView = updated.lastView
                        if let store = study.store {
                            // The suggested view remains usable if the optional cache cannot be written.
                            if (try? store.write(updated, replacing: loadedNotes, volume: loaded)) != nil {
                                loadedNotes = updated
                            }
                        }
                    }
                }
                volumeWindow?.close()
                mcpImage = nil
                mode.selectedSegment = 0
                panorama.setActive(false)
                mpr.setActive(false)
                volume = loaded
                notes = loadedNotes
                studyStore = study.store
                refreshBookmarkMenu()
                openedDemo = demonstration
                setActiveBookmark(nil)
                if !demonstration { lastOpenedFolder = url.deletingLastPathComponent() }
                fileLabel.stringValue = demonstration ? String(localized: "Демо · клинический снимок") : libraryTitle ?? link?.displayName ?? url.lastPathComponent
                fileLabel.toolTip = fileLabel.stringValue
                plane = .axial
                indices = [loaded.depth / 2, loaded.height / 2, loaded.width / 2]
                displayCeiling = min(65535, max(1, Double(loaded.peak ?? 0), loaded.windowWidth, loaded.windowCenter))
                let geometry = loaded.oriented ? String(localized: "R/L — правая/левая сторона пациента") : String(localized: "Стороны пациента не определены")
                let spacing = loaded.spacing.map { $0.formatted(.number.precision(.fractionLength(0...4))) }
                status.stringValue = String(localized: "Шаг вокселя \(spacing.joined(separator: " × ")) мм · \(geometry) · ⌥ и перетаскивание: яркость и контраст")
                updatePlane()
                mpr.load(loaded)
                let demoArches = demonstration ? Bundle.main.url(forResource: "DemoArches", withExtension: "json")
                    .flatMap { try? DemoStudy.arches(at: $0, for: loaded) } : nil
                let hasArch = panorama.load(loaded, notes: notes, demoArches: demoArches, automatic: suggestion)
                resetControls()
                if !hasArch, lastView?.location.isPanorama != true {
                    status.stringValue += String(localized: " · В разделе «Панорама» можно задать дугу вручную")
                }
                let openedNewPanorama = suggestion != nil && hasArch
                if !demonstration, let lastView, !openedNewPanorama || lastView.location.isPanorama {
                    restoreView(lastView)
                    setActiveBookmark(notes.lastBookmark)
                } else {
                    mode.selectedSegment = hasArch ? 1 : 2
                    changeMode()
                }
                if let link { updateRecent { $0.record(link) } }
                else if !demonstration && !fromLibrary { status.stringValue += String(localized: " · История не сохранена") }
                if let error = study.error {
                    status.stringValue += String(localized: " · Хранилище отметок недоступно")
                    showAlert(String(localized: "Не удалось прочитать сохранённые отметки и дуги"), error.localizedDescription)
                }
            case .failure(let choice as DICOMSeriesChoice):
                status.stringValue = previousStatus
                DICOMSeriesPicker.show(choice, on: window) { [weak self] selected in
                    self?.load(url, expected: expected, libraryTitle: libraryTitle, dicomSeries: selected)
                }
            case .failure(let error):
                status.stringValue = String(localized: "Не удалось открыть выбранный файл")
                view.message = String(localized: "Откройте снимок INV или DICOM")
                view.needsDisplay = true
                let alert = NSAlert()
                alert.messageText = String(localized: "Не удалось открыть снимок")
                alert.informativeText = expected == nil ? error.localizedDescription :
                    error.localizedDescription + "\n\n" + missingFileHelp(fromLibrary)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
            busy = false
            spinner.stopAnimation(nil)
            updateEnabled()
        }
    }

    private func updateEnabled() {
        panorama.allowsArchEditing = !busy
        cancelLoadButton.isHidden = !busy
        openButton.isEnabled = !busy
        welcome.isLoading = busy
        for control in [mode, planes, index, level, width, levelInput, widthInput, zoom, presets, reset] as [NSControl] {
            control.isEnabled = volume != nil && !busy
        }
        bookmarks.isEnabled = studyStore != nil && !busy
        exportItem?.isEnabled = volume != nil && !busy
        volumeButton.isEnabled = volume != nil && !busy
        volumeItem?.isEnabled = volumeButton.isEnabled
    }

    @objc private func cancelLoading() {
        guard busy else { return }
        loadID = UUID()
        readTask?.cancel()
        archTask?.cancel()
        readTask = nil
        archTask = nil
        busy = false
        status.stringValue = statusBeforeLoad
        view.message = String(localized: "Откройте снимок INV или DICOM")
        spinner.stopAnimation(nil)
        updateEnabled()
    }

    @objc private func showVolume() {
        guard let volume, !busy else { return }
        if let volumeWindow {
            volumeWindow.show()
        } else {
            let viewer = VolumeWindow(volume: volume)
            viewer.onClose = { [weak self] in
                self?.volumeWindow = nil
                self?.mcpVolumeActive = false
            }
            viewer.onActivate = { [weak self] in self?.mcpVolumeActive = true }
            volumeWindow = viewer
            viewer.show()
        }
        mcpVolumeActive = true
    }

    @objc private func selectViewingMode(_ sender: NSMenuItem) {
        guard volume != nil, !busy else { return }
        mode.selectedSegment = sender.tag
        changeMode()
    }

    @objc private func changeMode() {
        let loaded = volume != nil
        let panoramic = loaded && mode.selectedSegment == 1
        let multi = loaded && mode.selectedSegment == 2
        welcome.isHidden = loaded
        for item in documentChrome { item.isHidden = !loaded }
        view.isHidden = !loaded || panoramic || multi
        navigation.isHidden = view.isHidden
        panorama.isHidden = !panoramic
        mpr.isHidden = !multi
        window.minSize = panoramic || multi ? NSSize(width: 840, height: 570) : NSSize(width: 730, height: 480)
        let size = window.contentView?.bounds.size ?? .zero
        if (panoramic || multi) && (size.width < 840 || size.height < 550) {
            window.setContentSize(NSSize(width: max(size.width, 840), height: max(size.height, 550)))
        }
        panorama.setActive(panoramic)
        mpr.setActive(multi)
        render()
        if loaded && !panoramic && !multi {
            window.makeFirstResponder(view)
        }
    }

    @objc private func changePlane() { setPlane(planes.selectedSegment) }

    private func setPlane(_ number: Int) {
        guard !busy, volume != nil, let selected = Plane(rawValue: number) else { return }
        plane = selected
        updatePlane()
        view.resetPan()
        render()
        window.makeFirstResponder(view)
    }

    private func updatePlane() {
        guard let volume else { return }
        for item in Plane.allCases {
            planes.setLabel(item.title(oriented: volume.oriented), forSegment: item.rawValue)
        }
        planes.selectedSegment = plane.rawValue
        index.maxValue = Double(max(1, volume.sliceCount(plane) - 1))
        index.doubleValue = Double(indices[plane.rawValue])
        view.sideLabels = volume.oriented ? plane.labels : []
        view.aspect = volume.sliceSize(plane).aspect
    }

    @objc private func changeIndex() {
        setIndex(Int(index.doubleValue.rounded()))
    }

    private func step(_ amount: Int) { setIndex(indices[plane.rawValue] + amount) }

    private func setIndex(_ value: Int) {
        guard let volume, !busy else { return }
        let current = min(volume.sliceCount(plane) - 1, max(0, value))
        index.doubleValue = Double(current)
        guard indices[plane.rawValue] != current else { return }
        indices[plane.rawValue] = current
        scheduleRender()
    }

    private var currentGray: GrayWindow {
        GrayWindow(width: width.doubleValue, center: level.doubleValue)
    }

    private func configureDisplayField(_ field: NSTextField, label: String, minimum: Double) {
        let number = NumberFormatter()
        number.numberStyle = .decimal
        number.usesGroupingSeparator = false
        number.maximumFractionDigits = 2
        number.minimum = NSNumber(value: minimum)
        number.maximum = 65535
        field.formatter = number
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.setAccessibilityLabel(label)
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        field.target = self
        field.action = #selector(editDisplayNumber(_:))
        field.cell?.sendsActionOnEndEditing = true
    }

    @objc private func editDisplayNumber(_ field: NSTextField) {
        guard !busy, volume != nil, let number = field.objectValue as? NSNumber else { return }
        let gray = currentGray
        let value = number.doubleValue
        setGray(field === widthInput ? GrayWindow(width: value, center: gray.center) :
            GrayWindow(width: gray.width, center: value))
    }

    private func setGray(_ requested: GrayWindow) {
        guard requested.width.isFinite, requested.center.isFinite else { return }
        let newWidth = min(65535, max(1, requested.width))
        let newCenter = min(65535, max(0, requested.center))
        width.maxValue = max(2, displayCeiling, newWidth)
        level.maxValue = max(1, displayCeiling, newCenter)
        width.doubleValue = newWidth
        level.doubleValue = newCenter
        changeDisplay()
    }

    private func adjustDisplay(x: CGFloat, y: CGFloat) {
        guard !busy, let volume else { return }
        let gray = currentGray
        let gain = max(1, volume.windowWidth / 260)
        setGray(GrayWindow(width: gray.width + Double(x) * gain, center: gray.center - Double(y) * gain))
    }

    @objc private func changeDisplay() {
        levelInput.objectValue = NSNumber(value: level.doubleValue)
        widthInput.objectValue = NSNumber(value: width.doubleValue)
        scheduleRender()
    }

    @objc private func changeZoom() {
        view.setZoom(zoom.doubleValue)
        applyDisplay()
    }

    @objc private func resetControls() {
        guard let volume else { return }
        setGray(GrayWindow(width: volume.windowWidth, center: volume.windowCenter))
        zoom.doubleValue = 1
        changeZoom()
        render()
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.render()
        }
    }

    private func render() {
        guard let volume else { return }
        applyDisplay()
        guard mode.selectedSegment == 0 else { return }
        let current = indices[plane.rawValue]
        let position = String(localized: "Срез \(current + 1) из \(volume.sliceCount(plane))")
        frameLabel.stringValue = position
        view.setAccessibilityValue(position)
        view.image = volume.image(plane, index: current, windowWidth: width.doubleValue, center: level.doubleValue)
    }

    private func applyDisplay() {
        let gray = GrayWindow(width: width.doubleValue, center: level.doubleValue)
        panorama.setDisplay(gray, zoom: zoom.doubleValue)
        mpr.setDisplay(gray, zoom: zoom.doubleValue)
    }

    @objc private func exportPNG() {
        guard !busy, volume != nil else { return }
        if let viewer = volumeWindow, viewer.isKeyWindow {
            do {
                let capture = try viewer.capturePNG()
                let host = viewer.exportWindow
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "CBCT-3D.png"
                panel.message = String(localized: "Сохраняется текущий объёмный вид без метаданных пациента.")
                panel.beginSheetModal(for: host) { [weak self] response in
                    guard response == .OK, let url = panel.url else { return }
                    Task { @MainActor [weak self] in
                        let result = await Task.detached(priority: .userInitiated) {
                            Result { try capture().write(to: url, options: .atomic) }
                        }.value
                        if case .failure(let error) = result {
                            self?.showAlert(String(localized: "Не удалось сохранить PNG"), error.localizedDescription)
                        }
                    }
                }
            } catch { showAlert(String(localized: "Изображение ещё не готово"), error.localizedDescription) }
            return
        }
        let frame = isPanoramic ? panorama.exportFrame : isMPR ? mpr.exportFrame : renderScheduled ? nil : view.exportFrame
        guard let frame else {
            showAlert(String(localized: "Изображение ещё не готово"), String(localized: "Дождитесь построения выбранного изображения и повторите экспорт."))
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "CBCT.png"
        panel.message = String(localized: "Сохраняется текущий вид без имени файла, заметки и метаданных пациента.")
        let ruler = NSButton(checkboxWithTitle: String(localized: "Включить линию и расстояние"), target: nil, action: nil)
        if frame.ruler != nil {
            ruler.state = .on
            ruler.sizeToFit()
            panel.accessoryView = ruler
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try PNGExport.encode(frame, includeRuler: ruler.state == .on).write(to: url, options: .atomic) }
            catch { self?.showAlert(String(localized: "Не удалось сохранить PNG"), error.localizedDescription) }
        }
    }

    private var isPanoramic: Bool { mode.selectedSegment == 1 }
    private var isMPR: Bool { mode.selectedSegment == 2 }

    private func readStudyNotes(for volume: Volume) -> (notes: StudyNotes, store: StudyStore?, error: Error?) {
        guard let fingerprint = volume.fingerprint,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let store = StudyStore(root: support.appendingPathComponent("INV Viewer/Studies", isDirectory: true),
                                     fingerprint: fingerprint) else { return (StudyNotes(), nil, StudyStoreError.invalid) }
        do {
            return (try store.read(volume: volume), store, nil)
        } catch {
            return (StudyNotes(), nil, error)
        }
    }

    @discardableResult
    private func saveNotes(_ updated: StudyNotes) -> Bool {
        guard let volume, let studyStore, !busy else {
            showAlert(String(localized: "Хранилище исследования недоступно"), String(localized: "Откройте снимок заново и повторите."))
            return false
        }
        do {
            try persistNotes(updated, store: studyStore, volume: volume)
            return true
        } catch {
            showAlert(String(localized: "Изменения не сохранены"), error.localizedDescription)
            return false
        }
    }

    private func persistNotes(_ updated: StudyNotes, store: StudyStore, volume: Volume) throws {
        guard updated != notes else { return }
        try store.write(updated, replacing: notes, volume: volume)
        notes = updated
        refreshBookmarkMenu()
    }

    private func refreshBookmarkMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Отметки"), action: nil, keyEquivalent: "")
        let add = menu.addItem(withTitle: String(localized: "Добавить отметку…"), action: #selector(addBookmark), keyEquivalent: "")
        add.target = self
        if !notes.bookmarks.isEmpty {
            menu.addItem(.separator())
            let remove = NSMenu(title: String(localized: "Удалить отметку"))
            let edit = NSMenu(title: String(localized: "Изменить отметку…"))
            for (index, mark) in notes.bookmarks.enumerated() {
                var title = "\(index + 1). \(mark.name)"
                if let volume, let distance = mark.ruler?.distance(in: volume, at: mark.location) {
                    let value = distance.formatted(.number.precision(.fractionLength(1)))
                    title += String(localized: " · \(value) мм")
                }
                let open = menu.addItem(withTitle: title, action: #selector(openBookmark), keyEquivalent: "")
                open.target = self
                open.representedObject = mark.id.uuidString
                let update = edit.addItem(withTitle: title, action: #selector(editBookmark(_:)), keyEquivalent: "")
                update.target = self
                update.representedObject = mark.id.uuidString
                let delete = remove.addItem(withTitle: title, action: #selector(removeBookmark), keyEquivalent: "")
                delete.target = self
                delete.representedObject = mark.id.uuidString
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Изменить отметку…"), action: nil, keyEquivalent: "").submenu = edit
            menu.addItem(withTitle: String(localized: "Удалить отметку…"), action: nil, keyEquivalent: "").submenu = remove
        }
        bookmarks.menu = menu
        bookmarks.selectItem(at: 0)
    }

    @objc private func addBookmark() { saveBookmark(requiresRuler: false) }
    @objc private func saveMeasurement() { saveBookmark(requiresRuler: true) }

    private func saveBookmark(requiresRuler: Bool) {
        guard let studyStore, volume != nil, !busy, window.attachedSheet == nil else { return }
        guard !panorama.isEditingArch else {
            showAlert(String(localized: "Сначала завершите правку дуги"), String(localized: "Нажмите «Готово» или «Отмена» в панораме."))
            return
        }
        guard notes.bookmarks.count < 100 else {
            showAlert(String(localized: "Достигнут предел в 100 отметок"), String(localized: "Удалите одну из отметок, чтобы добавить новую."))
            return
        }
        guard let state = viewingState() else {
            showAlert(String(localized: "Выберите участок на панораме"), String(localized: "Для отметки в этом режиме нужна дуга."))
            return
        }
        if requiresRuler && state.ruler == nil {
            showAlert(String(localized: "Измерение не завершено"),
                      String(localized: "Поставьте две точки линейкой в MPR или на крупном поперечном срезе."))
            return
        }
        let message = requiresRuler ? String(localized: "Сохранить измерение") : String(localized: "Сохранить положение")
        bookmarkEditor(title: message) { [weak self] name, annotation in
            guard let self, self.studyStore?.file == studyStore.file else { return }
            var updated = notes
            let mark = StudyBookmark(name: name, display: state.display, location: state.location,
                                     ruler: state.ruler, annotation: annotation)
            updated.bookmarks.append(mark)
            if saveNotes(updated) { setActiveBookmark(mark.id) }
        }
    }

    private func viewingState() -> SavedViewingState? {
        guard volume != nil, !panorama.isEditingArch else { return nil }
        let location: StudyBookmark.Location
        if isPanoramic {
            guard let position = panorama.bookmark else { return nil }
            location = .panorama(position)
        } else if isMPR {
            location = .mpr(mpr.pose, plane: mpr.activePlane.rawValue, main: mpr.mainPlane.rawValue)
        } else {
            location = .slice(plane: plane.rawValue, index: indices[plane.rawValue])
        }
        let display = SavedDisplay(width: width.doubleValue, level: level.doubleValue, zoom: zoom.doubleValue)
        let ruler = isPanoramic ? panorama.savedRuler : isMPR ? mpr.savedRuler : nil
        return SavedViewingState(display: display, location: location, ruler: ruler)
    }

    private func rememberView() {
        guard !openedDemo, let volume, let studyStore, let current = viewingState(),
              current.valid(in: volume) else { return }
        let id = notes.bookmarks.first { $0.id == activeBookmark && $0.location == current.location }?.id
        guard current != notes.lastView || id != notes.lastBookmark else { return }
        var updated = notes
        updated.lastView = current
        updated.lastBookmark = id
        do {
            try studyStore.write(updated, replacing: notes, volume: volume)
            notes = updated
        } catch {
            // A concurrently updated note must always take precedence over the view position.
            status.stringValue += String(localized: " · Последний вид не сохранён")
        }
    }

    private func bookmarkEditor(title: String, current: StudyBookmark? = nil,
                                accepts: @escaping (String, String?) -> Void) {
        let field = NSTextField(string: current?.name ?? "")
        field.placeholderString = String(localized: "Название отметки")
        field.setAccessibilityLabel(String(localized: "Название отметки"))
        let caption = NSTextField(labelWithString: String(localized: "Заметка (необязательно)"))
        let note = NSTextView()
        note.isRichText = false
        note.string = current?.annotation ?? ""
        note.font = .systemFont(ofSize: 13)
        note.setAccessibilityLabel(caption.stringValue)
        note.isVerticallyResizable = true
        note.textContainer?.widthTracksTextView = true
        note.autoresizingMask = [.width]
        note.textContainerInset = NSSize(width: 4, height: 4)
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = note
        scroll.heightAnchor.constraint(equalToConstant: 78).isActive = true
        let form = NSStackView(views: [field, caption, scroll])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.frame = CGRect(x: 0, y: 0, width: 360, height: 124)
        for item in form.arrangedSubviews {
            item.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = form
        alert.addButton(withTitle: String(localized: "Сохранить"))
        alert.addButton(withTitle: String(localized: "Отмена"))
        alert.layout()
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let annotation = note.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80, name.utf8.count <= 512,
                  name.rangeOfCharacter(from: .controlCharacters) == nil, StudyBookmark.validAnnotation(annotation) else {
                showAlert(String(localized: "Проверьте название и заметку"),
                          String(localized: "Название: одна строка до 80 символов. Заметка: до 2048 байт обычного текста."))
                return
            }
            accepts(name, annotation.isEmpty ? nil : annotation)
        }
    }

    @objc private func editBookmark(_ item: NSMenuItem) {
        guard let mark = bookmark(for: item), let path = studyStore?.file else { return }
        bookmarkEditor(title: String(localized: "Изменить отметку…"), current: mark) { [weak self] name, annotation in
            guard let self, studyStore?.file == path,
                  let index = notes.bookmarks.firstIndex(where: { $0.id == mark.id }) else { return }
            var updated = notes
            updated.bookmarks[index].name = name
            updated.bookmarks[index].annotation = annotation
            if saveNotes(updated), activeBookmark == mark.id { setActiveBookmark(mark.id) }
        }
    }

    private func setActiveBookmark(_ id: UUID?) {
        activeBookmark = id
        let mark = notes.bookmarks.first { $0.id == id }
        annotationButton.isHidden = mark?.annotation == nil
        annotationButton.toolTip = mark?.name
    }

    @objc private func showAnnotation() {
        guard let mark = notes.bookmarks.first(where: { $0.id == activeBookmark }), let text = mark.annotation else { return }
        showAlert(mark.name, text)
    }

    private func bookmark(for item: NSMenuItem) -> StudyBookmark? {
        guard let id = item.representedObject as? String, !busy, window.attachedSheet == nil else { return nil }
        return notes.bookmarks.first { $0.id.uuidString == id }
    }

    @objc private func openBookmark(_ item: NSMenuItem) {
        guard let mark = bookmark(for: item) else { return }
        guard !panorama.isEditingArch else {
            showAlert(String(localized: "Сначала завершите правку дуги"), String(localized: "Нажмите «Готово» или «Отмена» в панораме."))
            return
        }
        restoreView(mark.viewingState)
        setActiveBookmark(mark.id)
    }

    private func restoreView(_ saved: SavedViewingState) {
        setGray(GrayWindow(width: saved.display.width, center: saved.display.level))
        zoom.doubleValue = saved.display.zoom
        switch saved.location {
        case .slice(let rawPlane, let position):
            guard let savedPlane = Plane(rawValue: rawPlane) else { return }
            plane = savedPlane
            indices[rawPlane] = position
            updatePlane()
            mode.selectedSegment = 0
        case .panorama(let position):
            panorama.restore(position)
            if let ruler = saved.ruler { panorama.restoreRuler(ruler) }
            mode.selectedSegment = 1
        case .mpr(let pose, let rawPlane, let main):
            guard let savedPlane = Plane(rawValue: rawPlane), let primary = Plane(rawValue: main) else { return }
            mpr.apply(pose, plane: savedPlane, main: primary)
            if let ruler = saved.ruler { mpr.restoreRuler(ruler) }
            mode.selectedSegment = 2
        }
        changeZoom()
        changeMode()
    }

    @objc private func removeBookmark(_ item: NSMenuItem) {
        guard let mark = bookmark(for: item) else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Удалить отметку «\(mark.name)»?")
        alert.addButton(withTitle: String(localized: "Отмена"))
        alert.addButton(withTitle: String(localized: "Удалить"))
        alert.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .alertSecondButtonReturn,
                  notes.bookmarks.contains(where: { $0.id == mark.id }) else { return }
            var updated = notes
            updated.bookmarks.removeAll { $0.id == mark.id }
            if updated.lastBookmark == mark.id { updated.lastBookmark = nil }
            if saveNotes(updated), activeBookmark == mark.id { setActiveBookmark(nil) }
        }
    }

    private func showAlert(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func handleMCP(_ data: Data) -> LocalBridge.Response {
        do {
            let call = try ViewerCall.decode(data)
            if call.name == .getState { return .immediate(try ViewerMCP.reply(mcpState())) }
            guard let volume, !busy, window.attachedSheet == nil else {
                throw ViewerToolError(String(localized: "Дождитесь загрузки снимка или закройте диалог в INV Viewer."))
            }
            guard !panorama.isEditingArch else {
                throw ViewerToolError(String(localized: "Сначала завершите редактирование дуги."))
            }
            switch call.name {
            case .getState:
                break
            case .setView:
                guard let target = call.arguments?.view else { throw ViewerToolError(String(localized: "Укажите view.")) }
                try setMCPView(target)
            case .navigate:
                try navigateMCP(call.arguments, volume: volume)
            case .getImage:
                return try captureMCP(call.arguments?.mpr_plane?.plane, volume: volume)
            case .configureVolume:
                guard mcpVolumeActive, let volumeWindow, let args = call.arguments else {
                    throw ViewerToolError(String(localized: "Сначала откройте объёмный 3D."))
                }
                try volumeWindow.configureMCP(args)
            case .measure:
                guard let args = call.arguments else { throw BridgeError.invalidMessage }
                let distance = try measureMCP(args, volume: volume)
                var state = mcpState()
                state["distance_mm"] = distance
                return .immediate(try ViewerMCP.reply(state))
            case .bookmark:
                guard let args = call.arguments else { throw BridgeError.invalidMessage }
                return .immediate(try ViewerMCP.reply(try bookmarkMCP(args, volume: volume)))
            }
            return .immediate(try ViewerMCP.reply(mcpState()))
        } catch is DecodingError {
            return .immediate(ViewerMCP.failureData(String(localized: "Неизвестная команда или неверные аргументы.")))
        } catch {
            return .immediate(ViewerMCP.failureData(error.localizedDescription))
        }
    }

    private func setMCPView(_ target: MCPView) throws {
        if target == .volume3D {
            showVolume()
            return
        }
        if target == .crossSection, !panorama.hasArch {
            throw ViewerToolError(String(localized: "Сначала задайте дугу в панораме."))
        }
        volumeWindow?.close()
        if let targetPlane = target.plane {
            plane = targetPlane
            updatePlane()
            mode.selectedSegment = 0
            changeMode()
        } else if target == .mpr {
            mode.selectedSegment = 2
            changeMode()
        } else {
            if !isPanoramic {
                mode.selectedSegment = 1
                changeMode()
            }
            panorama.setMCPDetail(target == .crossSection)
        }
    }

    private func navigateMCP(_ arguments: ViewerCall.Arguments?, volume: Volume) throws {
        guard let args = arguments else {
            throw ViewerToolError(String(localized: "Укажите ровно один параметр навигации."))
        }
        let count = [args.jaw != nil, args.position_mm != nil, args.slice != nil,
                     args.steps != nil, args.zoom != nil].filter { $0 }.count
        guard count == 1 else { throw ViewerToolError(String(localized: "Укажите ровно один параметр навигации.")) }
        guard !mcpVolumeActive else {
            throw ViewerToolError(String(localized: "Для настройки 3D используйте configure_volume."))
        }
        if args.mpr_plane != nil, !isMPR || (args.steps == nil && args.slice == nil) {
            throw ViewerToolError(String(localized: "Укажите mpr_plane только для среза или шага в MPR."))
        }
        if let factor = args.zoom {
            guard (1...4).contains(factor) else { throw ViewerToolError(String(localized: "Масштаб должен быть от 1 до 4.")) }
            zoom.doubleValue = factor
            changeZoom()
        } else if let steps = args.steps, !(-100...100).contains(steps) {
            throw ViewerToolError(String(localized: "Число шагов должно быть от −100 до 100."))
        } else if isPanoramic {
            try panorama.navigateMCP(args)
        } else if isMPR {
            let active = args.mpr_plane?.plane ?? mpr.activePlane
            if let steps = args.steps {
                mpr.step(steps, in: active)
            } else if let slice = args.slice, mpr.pose.isStraight, (1...volume.sliceCount(active)).contains(slice) {
                mpr.setSlice(slice - 1, in: active)
            } else {
                throw ViewerToolError(String(localized: "В MPR укажите steps или номер среза для прямой плоскости."))
            }
        } else if let slice = args.slice, (1...volume.sliceCount(plane)).contains(slice) {
            setIndex(slice - 1)
        } else if let steps = args.steps {
            step(steps)
        } else {
            throw ViewerToolError(String(localized: "Для этой плоскости укажите номер среза или число шагов."))
        }
    }

    private func captureMCP(_ requestedPlane: Plane?, volume: Volume) throws -> LocalBridge.Response {
        if requestedPlane != nil, !isMPR || mcpVolumeActive {
            throw ViewerToolError(String(localized: "Параметр mpr_plane доступен только в MPR."))
        }
        var state = mcpState()
        if mcpVolumeActive, let volumeWindow {
            let capture = try volumeWindow.captureMCP()
            let snapshot = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
            mcpImage = nil
            return .deferred {
                do { return try ViewerMCP.reply(stateData: snapshot, image: capture()) }
                catch { return ViewerMCP.failureData(error.localizedDescription) }
            }
        }

        let image: CGImage?
        var measurementLocation: StudyBookmark.Location?
        if isMPR {
            let imagePlane = requestedPlane ?? mpr.activePlane
            let frame = MPRFrame(volume, plane: imagePlane, pose: mpr.pose)
            image = mpr.currentImage(in: imagePlane)
            state["image_plane"] = MCPView(imagePlane).rawValue
            state["image_extent_mm"] = [frame.size.x, frame.size.y]
            state["image_offset_mm"] = frame.offset
            if volume.oriented { state["image_side_labels"] = frame.sideLabels }
            if mpr.pose.isStraight {
                let index = Int((frame.offset / volume.spacing[imagePlane.normalAxis]).rounded())
                state["image_slice"] = min(volume.sliceCount(imagePlane), max(1, index + 1))
            }
            measurementLocation = .mpr(mpr.pose, plane: imagePlane.rawValue, main: mpr.mainPlane.rawValue)
        } else if isPanoramic {
            image = panorama.currentMCPImage
            if let position = panorama.bookmark, position.detailed {
                state["image_extent_mm"] = [panorama.detailWidthMM, volume.physicalHeight]
                measurementLocation = .panorama(position)
            }
        } else {
            image = renderScheduled ? nil : view.image
            state["image_plane"] = MCPView(plane).rawValue
            state["image_slice"] = indices[plane.rawValue] + 1
            if volume.oriented { state["image_side_labels"] = plane.labels }
        }
        guard let image,
              let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ViewerToolError(String(localized: "Изображение ещё не готово. Повторите запрос после отрисовки."))
        }
        mcpImage = measurementLocation.map { (UUID(), $0) }
        if let mcpImage { state["image_id"] = mcpImage.id.uuidString }
        state["image_size_px"] = [image.width, image.height]
        return .immediate(try ViewerMCP.reply(state, image: bytes))
    }

    private func measureMCP(_ args: ViewerCall.Arguments, volume: Volume) throws -> Double {
        guard let first = args.first, let second = args.second, first.count == 2, second.count == 2,
              (first + second).allSatisfy({ (0...1).contains($0) }), first != second else {
            throw ViewerToolError(String(localized: "Укажите две разные точки в пределах изображения."))
        }
        guard !mcpVolumeActive, let image = mcpImage, args.image_id == image.id else {
            throw ViewerToolError(String(localized: "Получите новое изображение MPR или поперечного среза."))
        }
        let a = SIMD2(first[0], first[1]), b = SIMD2(second[0], second[1])
        let ruler: SavedRuler
        let targetPlane: Plane?
        switch image.location {
        case let .mpr(pose, rawPlane, _):
            guard isMPR, mpr.pose == pose, let plane = Plane(rawValue: rawPlane) else {
                throw ViewerToolError(String(localized: "Получите новое изображение MPR или поперечного среза."))
            }
            let frame = MPRFrame(volume, plane: plane, pose: pose)
            ruler = .mpr(first: frame.location(a), second: frame.location(b))
            targetPlane = plane
        case let .panorama(position):
            guard isPanoramic, panorama.bookmark == position else {
                throw ViewerToolError(String(localized: "Получите новое изображение MPR или поперечного среза."))
            }
            ruler = .section(first: a, second: b)
            targetPlane = nil
        case .slice:
            throw BridgeError.invalidMessage
        }
        guard let distance = ruler.distance(in: volume, at: image.location) else {
            throw ViewerToolError(String(localized: "Одна из точек находится за пределами снимка."))
        }
        if let targetPlane { mpr.restoreRuler(ruler, in: targetPlane) }
        else { panorama.restoreRuler(ruler) }
        return distance
    }

    private func bookmarkMCP(_ args: ViewerCall.Arguments, volume: Volume) throws -> [String: Any] {
        switch args.action {
        case .list:
            guard args.id == nil, args.name == nil, args.note == nil else { throw BridgeError.invalidMessage }
            var state = mcpState()
            state["bookmarks"] = notes.bookmarks.map { bookmarkMCPState($0, volume: volume) }
            return state
        case .save:
            guard args.id == nil, let name = args.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let saved = viewingState(), !mcpVolumeActive, let store = studyStore else {
                throw ViewerToolError(String(localized: "Для отметки укажите название и откройте срез, панораму или MPR."))
            }
            let note = args.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let mark = StudyBookmark(name: name, display: saved.display, location: saved.location,
                                     ruler: saved.ruler, annotation: note.flatMap { $0.isEmpty ? nil : $0 })
            guard mark.valid(in: volume), name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ViewerToolError(String(localized: "Название или заметка отметки недопустимы."))
            }
            if let existing = notes.bookmarks.first(where: {
                $0.name == mark.name && $0.annotation == mark.annotation && $0.viewingState == mark.viewingState
            }) {
                setActiveBookmark(existing.id)
                return bookmarkMCPResult(existing, volume: volume)
            }
            guard notes.bookmarks.count < 100 else {
                throw ViewerToolError(String(localized: "Достигнут предел в 100 отметок"))
            }
            var updated = notes
            updated.bookmarks.append(mark)
            try persistNotes(updated, store: store, volume: volume)
            setActiveBookmark(mark.id)
            return bookmarkMCPResult(mark, volume: volume)
        case .open:
            guard args.name == nil, args.note == nil, let id = args.id,
                  let mark = notes.bookmarks.first(where: { $0.id == id }) else {
                throw ViewerToolError(String(localized: "Отметка с таким ID отсутствует в открытом исследовании."))
            }
            volumeWindow?.close()
            restoreView(mark.viewingState)
            setActiveBookmark(mark.id)
            return bookmarkMCPResult(mark, volume: volume)
        case nil:
            throw BridgeError.invalidMessage
        }
    }

    private func bookmarkMCPResult(_ mark: StudyBookmark, volume: Volume) -> [String: Any] {
        var state = mcpState()
        state["bookmark"] = bookmarkMCPState(mark, volume: volume)
        return state
    }

    private func bookmarkMCPState(_ mark: StudyBookmark, volume: Volume) -> [String: Any] {
        var state: [String: Any] = ["id": mark.id.uuidString, "name": mark.name, "has_note": mark.annotation != nil]
        if let distance = mark.ruler?.distance(in: volume, at: mark.location) { state["distance_mm"] = distance }
        return state
    }

    private func mcpState() -> [String: Any] {
        var result: [String: Any] = ["loaded": volume != nil, "loading": busy]
        guard let volume else { return result }
        result["dimensions"] = [volume.width, volume.height, volume.depth]
        result["spacing_mm"] = volume.spacing
        result["oriented"] = volume.oriented
        if mcpVolumeActive, let volumeWindow {
            result.merge(volumeWindow.mcpState) { _, new in new }
            return result
        }
        result["zoom"] = zoom.doubleValue
        if let saved = viewingState(), let distance = saved.ruler?.distance(in: volume, at: saved.location) {
            result["distance_mm"] = distance
        }
        if isPanoramic {
            result.merge(panorama.mcpState) { _, new in new }
        } else if isMPR {
            let point = mpr.pose.point
            let active = mpr.activePlane
            result["view"] = MCPView.mpr.rawValue
            result["active_plane"] = MCPView(active).rawValue
            result["main_plane"] = MCPView(mpr.mainPlane).rawValue
            result["cursor_mm"] = [point.x, point.y, point.z]
            result["oblique"] = !mpr.pose.isStraight
            let quaternion = mpr.pose.quaternion
            result["rotation_xyzw"] = [quaternion.x, quaternion.y, quaternion.z, quaternion.w]
            let roll = mpr.pose.roll
            result["roll_rad"] = [roll.x, roll.y, roll.z]
        } else {
            result["view"] = MCPView(plane).rawValue
            result["slice"] = indices[plane.rawValue] + 1
            result["slice_count"] = volume.sliceCount(plane)
        }
        return result
    }
}

@main
enum Main {
    @MainActor
    static func main() {
        if CommandLine.arguments.dropFirst() == ["--mcp"] {
            ViewerMCP.serve()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Viewer()
        app.delegate = delegate
        app.run()
    }
}
