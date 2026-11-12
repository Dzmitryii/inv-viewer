import AppKit

@MainActor
enum DICOMSeriesPicker {
    static func show(_ choice: DICOMSeriesChoice, on window: NSWindow, completion: @escaping (String) -> Void) {
        let series = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        series.setAccessibilityLabel(String(localized: "Серия КТ"))
        for (index, option) in choice.options.enumerated() {
            let number = option.number ?? index + 1
            let size = "\(option.width) × \(option.height)"
            series.addItem(withTitle: String(localized: "Серия \(number) · \(size) · Срезов: \(option.slices)"))
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Выберите серию КТ")
        alert.informativeText = choice.localizedDescription
        alert.accessoryView = series
        alert.addButton(withTitle: String(localized: "Открыть серию"))
        alert.addButton(withTitle: String(localized: "Отмена"))
        alert.beginSheetModal(for: window) { response in
            let index = series.indexOfSelectedItem
            if response == .alertFirstButtonReturn, choice.options.indices.contains(index) {
                completion(choice.options[index].id)
            }
        }
    }
}
