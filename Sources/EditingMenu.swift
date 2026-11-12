import AppKit

@MainActor
enum EditingMenu {
    static func make() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Правка"))
        let undo = menu.addItem(withTitle: String(localized: "Отменить действие"), action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        undo.target = nil
        let redo = menu.addItem(withTitle: String(localized: "Повторить действие"), action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        for (title, action, key) in [
            (String(localized: "Вырезать"), #selector(NSText.cut(_:)), "x"),
            (String(localized: "Скопировать"), #selector(NSText.copy(_:)), "c"),
            (String(localized: "Вставить"), #selector(NSText.paste(_:)), "v"),
            (String(localized: "Выделить всё"), #selector(NSText.selectAll(_:)), "a")
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = nil
        }
        return menu
    }
}
