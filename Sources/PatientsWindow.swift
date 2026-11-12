import AppKit
import UniformTypeIdentifiers

@MainActor
final class PatientsWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let store: LocalDocument<StudyLibrary>
    private var catalog = StudyLibrary()
    private var visiblePatients: [LibraryPatient] = []
    private var currentPatient: LibraryPatient? {
        visiblePatients.indices.contains(patients.selectedRow) ? visiblePatients[patients.selectedRow] : nil
    }
    private var visibleStudies: [PatientStudy] = []
    private var currentStudy: PatientStudy? {
        let studies = visibleStudies
        return studies.indices.contains(studiesTable.selectedRow) ? studies[studiesTable.selectedRow] : nil
    }
    private var loading = false
    private var readable = false
    private let search = NSSearchField()
    private let patients = NSTableView()
    private let studiesTable = NSTableView()
    private let patientTitle = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let add = NSButton(title: String(localized: "Новый пациент…"), target: nil, action: nil)
    private let patientActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private let attach = NSButton(title: String(localized: "Добавить снимок…"), target: nil, action: nil)
    private let open = NSButton(title: String(localized: "Открыть снимок"), target: nil, action: nil)
    private let studyActions = NSPopUpButton(frame: .zero, pullsDown: true)
    var onOpen: ((LibraryPatient, PatientStudy) -> Void)?

    init(root: URL) {
        store = StudyLibrary.store(at: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 486),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = String(localized: "Пациенты")
        window.minSize = NSSize(width: 750, height: 405)
        window.isReleasedWhenClosed = false
        search.placeholderString = String(localized: "Поиск пациентов")
        search.setAccessibilityLabel(String(localized: "Поиск пациентов"))
        search.delegate = self
        search.sendsSearchStringImmediately = true
        patients.setAccessibilityLabel(String(localized: "Пациенты"))
        studiesTable.setAccessibilityLabel(String(localized: "Снимки пациента"))
        for table in [patients, studiesTable] {
            table.style = .inset
            table.rowHeight = 24
            table.usesAlternatingRowBackgroundColors = true
            table.allowsColumnReordering = false
            table.dataSource = self
            table.delegate = self
        }
        addColumn(patients, id: "patient", title: String(localized: "Пациенты"), width: 210)
        patients.headerView = nil
        addColumn(studiesTable, id: "study", title: String(localized: "Исследование"), width: 354)
        addColumn(studiesTable, id: "date", title: String(localized: "Дата"), width: 122)
        studiesTable.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        studiesTable.target = self
        studiesTable.doubleAction = #selector(doubleClickStudy)
        wire(add, #selector(addPatient))
        wire(attach, #selector(addStudy))
        wire(open, #selector(openStudy))
        configure(patientActions, items: [
            (String(localized: "Переименовать пациента…"), #selector(renamePatient)),
            (String(localized: "Удалить карточку…"), #selector(removePatient))
        ])
        configure(studyActions, items: [
            (String(localized: "Изменить название и дату…"), #selector(editStudy)),
            (String(localized: "Перепривязать снимок…"), #selector(relinkStudy)),
            (String(localized: "Убрать снимок из карточки…"), #selector(removeStudy))
        ])
        patientTitle.font = .systemFont(ofSize: 22, weight: .semibold)
        patientTitle.lineBreakMode = .byTruncatingTail
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.lineBreakMode = .byTruncatingTail
        let privacy = NSTextField(wrappingLabelWithString:
            String(localized: "Библиотека хранится на этом Mac. Снимки остаются в исходных папках."))
        privacy.font = .systemFont(ofSize: 12)
        privacy.textColor = .secondaryLabelColor
        let left = column([search, scroller(patients), row([add, patientActions])])
        let right = column([patientTitle, privacy, scroller(studiesTable), status, row([attach, NSView(), studyActions, open])])
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        left.widthAnchor.constraint(equalToConstant: 221).isActive = true
        let content = NSView()
        let layout = NSStackView(views: [left, separator, right])
        layout.orientation = .horizontal
        layout.alignment = .top
        layout.spacing = 15
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            left.heightAnchor.constraint(equalTo: layout.heightAnchor),
            right.heightAnchor.constraint(equalTo: layout.heightAnchor),
            separator.heightAnchor.constraint(equalTo: layout.heightAnchor)
        ])
        window.contentView = content
        window.initialFirstResponder = search
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        if !loading {
            do {
                catalog = try store.read(default: StudyLibrary(), valid: { $0.valid })
                readable = true
            } catch {
                readable = false
            }
            refresh(patient: currentPatient?.id, study: currentStudy?.id)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        return stack
    }

    private func scroller(_ table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 126).isActive = true
        return scroll
    }

    private func addColumn(_ table: NSTableView, id: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = id == "date" ? 100 : 130
        column.resizingMask = id == "date" ? [.userResizingMask] : [.autoresizingMask, .userResizingMask]
        table.addTableColumn(column)
    }

    private func wire(_ button: NSButton, _ action: Selector) {
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configure(_ popup: NSPopUpButton, items: [(String, Selector)]) {
        let title = String(localized: "Действия")
        popup.addItem(withTitle: title)
        popup.setAccessibilityLabel(title)
        popup.menu?.items[0].image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        for (title, selector) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.action = selector
            popup.lastItem?.target = self
        }
        popup.setContentHuggingPriority(.required, for: .horizontal)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === patients ? visiblePatients.count : visibleStudies.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === patients {
            guard visiblePatients.indices.contains(row) else { return nil }
            text = visiblePatients[row].name
        } else {
            let studies = visibleStudies
            guard studies.indices.contains(row) else { return nil }
            let study = studies[row]
            text = tableColumn?.identifier.rawValue == "date" ?
                study.date.formatted(date: .abbreviated, time: .omitted) : study.title
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === patients { refreshStudies() }
        updateControls()
    }

    func controlTextDidChange(_ obj: Notification) { refresh(patient: currentPatient?.id) }

    private func refresh(patient: UUID?, study: UUID? = nil) {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visiblePatients = readable ? catalog.patients.filter { query.isEmpty || $0.name.localizedStandardContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : []
        patients.reloadData()
        if let row = visiblePatients.firstIndex(where: { $0.id == patient }) ?? visiblePatients.indices.first {
            patients.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            patients.deselectAll(nil)
        }
        refreshStudies(study: study)
    }

    private func refreshStudies(study: UUID? = nil) {
        visibleStudies = currentPatient?.studies.sorted { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) } ?? []
        studiesTable.reloadData()
        if let row = visibleStudies.firstIndex(where: { $0.id == study }) {
            studiesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            studiesTable.deselectAll(nil)
        }
        updateControls()
    }

    private func updateControls() {
        add.isEnabled = readable && !loading
        search.isEnabled = readable && !loading
        patientActions.isEnabled = currentPatient != nil && !loading
        attach.isEnabled = patientActions.isEnabled
        studyActions.isEnabled = currentStudy != nil && !loading
        open.isEnabled = studyActions.isEnabled
        patientTitle.stringValue = currentPatient?.name ?? String(localized: "Снимки пациента")
        status.stringValue = if loading { String(localized: "Проверяю снимок…") }
        else if !readable { String(localized: "Не удалось прочитать библиотеку. Данные не изменены.") }
        else if catalog.patients.isEmpty { String(localized: "Создайте карточку пациента, чтобы добавить снимок.") }
        else if currentPatient == nil { String(localized: "Пациенты не найдены.") }
        else if visibleStudies.isEmpty { String(localized: "Добавьте первый снимок пациента.") }
        else { String(localized: "Двойной щелчок открывает снимок.") }
    }

    private func commit(_ next: StudyLibrary, patient: UUID? = nil, study: UUID? = nil) {
        do {
            try store.write(next, replacing: catalog, default: StudyLibrary(), valid: { $0.valid })
            catalog = next
            refresh(patient: patient, study: study)
        } catch {
            show()
            errorAlert(error)
        }
    }

    private func edit(title: String, field: String, value: String, date: Date? = nil,
                      accepts: @escaping (String, Date?) -> Void) {
        guard let window, !loading else { return }
        let input = NSTextField(string: value)
        input.setAccessibilityLabel(field)
        let dateField = NSDatePicker()
        dateField.datePickerStyle = .textFieldAndStepper
        dateField.datePickerElements = .yearMonthDay
        dateField.dateValue = date ?? Date()
        dateField.setAccessibilityLabel(String(localized: "Дата"))
        var fields: [NSView] = [NSTextField(labelWithString: field), input]
        if date != nil { fields += [NSTextField(labelWithString: String(localized: "Дата")), dateField] }
        let form = column(fields)
        form.frame = NSRect(x: 0, y: 0, width: 322, height: date == nil ? 60 : 120)
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = form
        alert.addButton(withTitle: String(localized: "Сохранить"))
        alert.addButton(withTitle: String(localized: "Отмена"))
        alert.layout()
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard StudyLibrary.validName(name) else {
                self?.edit(title: title, field: field, value: input.stringValue, date: date == nil ? nil : dateField.dateValue, accepts: accepts)
                return
            }
            accepts(name, date == nil ? nil : dateField.dateValue)
        }
    }

    @objc private func addPatient() {
        edit(title: String(localized: "Новый пациент"), field: String(localized: "Имя или код пациента"), value: "") { [weak self] name, _ in
            guard let self else { return }
            let patient = LibraryPatient(name: name)
            var next = catalog
            next.patients.append(patient)
            search.stringValue = ""
            commit(next, patient: patient.id)
        }
    }

    @objc private func renamePatient() {
        guard let patient = currentPatient else { return }
        edit(title: String(localized: "Переименовать пациента…"), field: String(localized: "Имя или код пациента"), value: patient.name) { [weak self] name, _ in
            guard let self, let i = catalog.patients.firstIndex(where: { $0.id == patient.id }) else { return }
            var next = catalog
            next.patients[i].name = name
            search.stringValue = ""
            commit(next, patient: patient.id)
        }
    }

    private func confirm(_ title: String, action: @escaping () -> Void) {
        guard let window, !loading else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(localized: "Исходные файлы, отметки и измерения останутся на диске.")
        alert.addButton(withTitle: String(localized: "Отмена"))
        alert.addButton(withTitle: String(localized: "Убрать из библиотеки")).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { action() } }
    }

    @objc private func removePatient() {
        guard let patient = currentPatient else { return }
        confirm(String(localized: "Удалить карточку…")) { [weak self] in
            guard let self else { return }
            var next = catalog
            next.patients.removeAll { $0.id == patient.id }
            commit(next)
        }
    }

    @objc private func removeStudy() {
        guard let patient = currentPatient, let study = currentStudy else { return }
        confirm(String(localized: "Убрать снимок из карточки…")) { [weak self] in
            guard let self, let i = catalog.patients.firstIndex(where: { $0.id == patient.id }) else { return }
            var next = catalog
            next.patients[i].studies.removeAll { $0.id == study.id }
            commit(next, patient: patient.id)
        }
    }

    @objc private func editStudy() {
        guard let patient = currentPatient, let study = currentStudy else { return }
        studyDetails(title: study.title, date: study.date) { [weak self] title, date in
            guard let self, let i = catalog.patients.firstIndex(where: { $0.id == patient.id }),
                  let j = catalog.patients[i].studies.firstIndex(where: { $0.id == study.id }) else { return }
            var next = catalog
            next.patients[i].studies[j].title = title
            next.patients[i].studies[j].date = date
            commit(next, patient: patient.id, study: study.id)
        }
    }

    private func studyDetails(title: String, date: Date, accepts: @escaping (String, Date) -> Void) {
        edit(title: String(localized: "Изменить название и дату…"), field: String(localized: "Название исследования"),
             value: title, date: date) { name, newDate in accepts(name, newDate ?? date) }
    }

    @objc private func doubleClickStudy() {
        guard studiesTable.clickedRow >= 0 else { return }
        openStudy()
    }

    @objc private func openStudy() {
        guard !loading, let patient = currentPatient, let study = currentStudy else { return }
        onOpen?(patient, study)
    }

    @objc private func addStudy() { selectFile(replacing: nil) }
    @objc private func relinkStudy() {
        guard let study = currentStudy else { return }
        selectFile(replacing: study)
    }

    private func selectFile(replacing study: PatientStudy?) {
        guard !loading, let patient = currentPatient, let window else { return }
        let panel = NSOpenPanel()
        panel.message = String(localized: "Выберите снимок INV, файл DICOM или папку экспорта КТ.")
        panel.allowedContentTypes = StudyFile.contentTypes
        panel.canChooseDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.verifyFile(url, patient: patient.id, replacing: study, dicomSeries: study?.link.dicomSeries)
        }
    }

    private func verifyFile(_ url: URL, patient: UUID, replacing study: PatientStudy?, dicomSeries: String?) {
        loading = true
        updateControls()
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let volume = try Volume.read(url, dicomSeries: dicomSeries)
                    guard let fingerprint = volume.fingerprint else { throw StudyLibraryError.invalid }
                    if let study, !volume.matchesFingerprint(study.link.fingerprint) { throw StudyLibraryError.differentScan }
                    let link = try ScanLink.make(url, fingerprint: fingerprint, dicomSeries: volume.dicomSeries, seriesNumber: volume.dicomSeriesNumber)
                    return (link, volume.legacyFingerprints)
                }
            }.value
            guard let self else { return }
            loading = false
            updateControls()
            do {
                let (link, aliases) = try result.get()
                guard let i = catalog.patients.firstIndex(where: { $0.id == patient }) else { return }
                if let study, let j = catalog.patients[i].studies.firstIndex(where: { $0.id == study.id }) {
                    var next = catalog
                    next.patients[i].studies[j].link = link
                    commit(next, patient: patient, study: study.id)
                    return
                }
                guard !catalog.patients[i].studies.contains(where: { $0.link.fingerprint == link.fingerprint || aliases.contains($0.link.fingerprint) }) else {
                    throw StudyLibraryError.duplicate
                }
                let name = (link.dicomSeries == nil ? url.deletingPathExtension().lastPathComponent : link.displayName)
                    .components(separatedBy: .controlCharacters).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = String(localized: "Исследование КЛКТ")
                // File timestamps are only defaults; the study date is editable.
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                studyDetails(title: StudyLibrary.validName(name) ? name : fallback,
                             date: values?.contentModificationDate ?? Date()) { [weak self] title, date in
                    guard let self, let i = catalog.patients.firstIndex(where: { $0.id == patient }) else { return }
                    let entry = PatientStudy(title: title, date: date, link: link)
                    var next = catalog
                    next.patients[i].studies.append(entry)
                    commit(next, patient: patient, study: entry.id)
                }
            } catch let choice as DICOMSeriesChoice {
                guard let window else { return }
                DICOMSeriesPicker.show(choice, on: window) { [weak self] selected in
                    self?.verifyFile(url, patient: patient, replacing: study, dicomSeries: selected)
                }
            } catch { errorAlert(error) }
        }
    }

    private func errorAlert(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Не удалось изменить библиотеку")
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
