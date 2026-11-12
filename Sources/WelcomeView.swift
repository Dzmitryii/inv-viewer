import AppKit

@MainActor
final class WelcomeView: NSView {
    var onOpen: (() -> Void)?
    var onPatients: (() -> Void)?
    var onResume: (() -> Void)?
    var onDemo: (() -> Void)?
    var onDrop: ((URL) -> Void)?
    var onCancel: (() -> Void)?
    private let cancel = NSButton(title: String(localized: "Отменить загрузку"), target: nil, action: nil)

    private let resume = NSButton(title: String(localized: "Открыть последний снимок"), target: nil, action: nil)
    private let open = NSButton(title: String(localized: "Открыть снимок…"), target: nil, action: nil)
    private let language = NSPopUpButton(frame: .zero, pullsDown: true)
    private let demo = NSButton(title: String(localized: "Открыть демо"), target: nil, action: nil)
    private let hint = NSTextField(labelWithString: String(localized: "Перетащите файл INV, DICOM или папку серии в окно."))

    var hasRecentScan = false {
        didSet { resume.isHidden = !hasRecentScan }
    }

    var isLoading = false {
        didSet {
            cancel.isHidden = !isLoading
            open.isEnabled = !isLoading
            demo.isEnabled = !isLoading
            resume.isEnabled = !isLoading
            hint.stringValue = isLoading ? String(localized: "Читаю снимок…") :
                String(localized: "Перетащите файл INV, DICOM или папку серии в окно.")
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])

        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 90).isActive = true
        icon.heightAnchor.constraint(equalTo: icon.widthAnchor).isActive = true

        let name = NSTextField(labelWithString: "INV Viewer")
        name.font = .systemFont(ofSize: 36, weight: .semibold)
        name.alignment = .center
        let description = NSTextField(wrappingLabelWithString:
            String(localized: "Просмотр стоматологических КЛКТ на Mac"))
        description.font = .systemFont(ofSize: 17, weight: .medium)
        description.textColor = .secondaryLabelColor
        description.alignment = .center
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        open.bezelStyle = .rounded
        open.controlSize = .large
        open.keyEquivalent = "\r"
        open.target = self
        open.action = #selector(pickFile)
        demo.bezelStyle = .rounded
        demo.controlSize = .large
        demo.target = self
        demo.action = #selector(pickDemo)

        let patients = NSButton(title: String(localized: "Пациенты"), target: self, action: #selector(pickPatients))
        patients.bezelStyle = .rounded
        patients.controlSize = .large
        patients.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        patients.imagePosition = .imageLeft
        language.bezelStyle = .rounded
        language.setAccessibilityLabel("Русский / English")
        language.toolTip = "Смена языка перезапустит приложение · Changing language reopens the app"
        language.translatesAutoresizingMaskIntoConstraints = false
        addSubview(language)
        NSLayoutConstraint.activate([
            language.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            language.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3)
        ])

        let actions = NSStackView(views: [open, patients, demo])
        actions.orientation = .horizontal
        actions.spacing = 10
        resume.bezelStyle = .inline
        resume.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        resume.imagePosition = .imageLeft
        resume.target = self
        resume.action = #selector(resumeScan)
        resume.isHidden = true

        cancel.target = self
        cancel.action = #selector(cancelLoading)
        cancel.bezelStyle = .rounded
        cancel.isHidden = true
        let stack = NSStackView(views: [icon, name, description, actions, hint, cancel, resume])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(20, after: description)
        stack.setCustomSpacing(12, after: actions)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 14),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        ])
        setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    required init?(coder: NSCoder) { nil }

    func setLanguageMenu(_ menu: NSMenu) {
        let title = NSMenuItem(title: "Русский / English", action: nil, keyEquivalent: "")
        title.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        menu.insertItem(title, at: 0)
        language.menu = menu
        language.selectItem(at: 0)
    }

    @objc private func pickFile() { onOpen?() }
    @objc private func pickPatients() { onPatients?() }
    @objc private func resumeScan() { onResume?() }
    @objc private func pickDemo() { onDemo?() }
    @objc private func cancelLoading() { onCancel?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        !isLoading && studyURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !isLoading, let url = studyURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }
}

@MainActor
func studyURL(from sender: NSDraggingInfo) -> URL? {
    let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true])
    guard let url = items?.first as? URL, StudyFile.accepts(url) else { return nil }
    return url
}
