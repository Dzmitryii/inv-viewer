import AppKit

@MainActor
final class ImagePresets: NSPopUpButton {
    private struct Preset: Codable {
        let name: String
        let gray: GrayWindow

        var valid: Bool {
            StudyLibrary.validName(name) && name.count <= 60 &&
                (1...65535).contains(gray.width) && (0...65535).contains(gray.center)
        }
    }

    var current: (() -> GrayWindow?)?
    var apply: ((GrayWindow) -> Void)?
    weak var hostWindow: NSWindow?
    private let preference = "imageWindowPresetsV1"
    private var presets: [Preset] = []

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        if let data = UserDefaults.standard.data(forKey: preference), data.count <= 16_384,
           let values = try? JSONDecoder().decode([Preset].self, from: data), values.count <= 12,
           values.allSatisfy(\.valid) {
            presets = values
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityLabel(String(localized: "Пресеты изображения"))
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    private func rebuild() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Пресеты"), action: nil, keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Сохранить пресет…"), action: #selector(addPreset), keyEquivalent: "").target = self
        if !presets.isEmpty {
            menu.addItem(.separator())
            let remove = NSMenu()
            for (index, preset) in presets.enumerated() {
                let item = menu.addItem(withTitle: preset.name, action: #selector(selectPreset(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                let delete = remove.addItem(withTitle: preset.name, action: #selector(deletePreset(_:)), keyEquivalent: "")
                delete.target = self
                delete.tag = index
            }
            menu.addItem(withTitle: String(localized: "Удалить пресет"), action: nil, keyEquivalent: "").submenu = remove
        }
        self.menu = menu
        selectItem(at: 0)
    }

    @objc private func addPreset() {
        guard let hostWindow, hostWindow.attachedSheet == nil, let gray = current?() else { return }
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = String(localized: "Название пресета")
        input.setAccessibilityLabel(String(localized: "Название пресета"))
        let alert = NSAlert()
        alert.messageText = String(localized: "Сохранить яркость и контраст")
        alert.informativeText = String(localized: "Чтобы обновить пресет, введите его текущее название.")
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "Сохранить"))
        alert.addButton(withTitle: String(localized: "Отмена"))
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: hostWindow) { [weak self] result in
            guard let self, result == .alertFirstButtonReturn else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let preset = Preset(name: name, gray: gray)
            guard preset.valid else {
                notice(String(localized: "Введите название пресета длиной до 60 символов."))
                return
            }
            if let index = presets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                presets[index] = preset
            } else if presets.count < 12 {
                presets.append(preset)
            } else {
                notice(String(localized: "Достигнут предел в 12 пресетов. Удалите один, чтобы добавить новый."))
                return
            }
            persist()
        }
    }

    @objc private func selectPreset(_ item: NSMenuItem) {
        if presets.indices.contains(item.tag) { apply?(presets[item.tag].gray) }
    }

    @objc private func deletePreset(_ item: NSMenuItem) {
        if presets.indices.contains(item.tag) { presets.remove(at: item.tag); persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: preference) }
        rebuild()
    }

    private func notice(_ title: String) {
        guard let hostWindow else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.beginSheetModal(for: hostWindow, completionHandler: nil)
    }
}
