import AppKit
import UniformTypeIdentifiers

@MainActor
final class BackupController {
    private let root: URL
    private unowned let window: NSWindow
    var onImport: (() -> Void)?
    private var running = false

    init(root: URL, window: NSWindow) { self.root = root; self.window = window }

    func exportBackup() {
        guard !running, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "INV-Viewer-backup.json"
        panel.message = String(localized: "Копия содержит карточки пациентов, дуги и отметки. Снимки нужно переносить отдельно.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let file = panel.url else { return }
            run(title: String(localized: "Создаю резервную копию…"), importing: false) { [root] in
                let accessed = file.startAccessingSecurityScopedResource()
                defer { if accessed { file.stopAccessingSecurityScopedResource() } }
                try LibraryBackup.snapshot(at: root).data().write(to: file, options: .atomic)
            }
        }
    }

    func importBackup() {
        guard !running, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Добавятся новые карточки и отметки. При конфликте импорт остановится без замены данных. На другом Mac перепривяжите снимки.")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let file = panel.url else { return }
            run(title: String(localized: "Проверяю и восстанавливаю копию…"), importing: true) { [root] in
                let accessed = file.startAccessingSecurityScopedResource()
                defer { if accessed { file.stopAccessingSecurityScopedResource() } }
                guard let data = try StoreAccess.read(file, limit: LibraryBackup.byteLimit) else { throw BackupError.invalid }
                try LibraryBackup.decode(data).restore(at: root)
            }
        }
    }

    private func run(title: String, importing: Bool, operation: @escaping @Sendable () throws -> Void) {
        running = true
        let progress = NSAlert()
        progress.messageText = title
        progress.addButton(withTitle: String(localized: "Подождите…")).isEnabled = false
        progress.beginSheetModal(for: window, completionHandler: nil)
        Task { @MainActor [self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try operation() } }.value
            window.endSheet(progress.window)
            progress.window.orderOut(nil)
            running = false
            let alert = NSAlert()
            switch result {
            case .success:
                if importing { onImport?() }
                alert.messageText = importing ? String(localized: "Резервная копия восстановлена") :
                    String(localized: "Резервная копия сохранена")
                if importing { alert.informativeText = String(localized: "Исходные снимки остаются отдельными файлами. Если ссылка недоступна, используйте «Перепривязать снимок…» в карточке пациента.") }
            case .failure(let error):
                alert.messageText = String(localized: "Операция с резервной копией не завершена")
                alert.informativeText = error.localizedDescription
            }
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }
}
