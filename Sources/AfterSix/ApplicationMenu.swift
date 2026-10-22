import AppKit

@MainActor
func makeApplicationMenu() -> NSMenu {
    let menu = NSMenu()
    let appMenu = NSMenu(title: "happylulu")
    appMenu.addItem(withTitle: L("happylulu 종료", "Quit happylulu"),
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    menu.addItem(appItem)

    let editMenu = NSMenu(title: L("편집", "Edit"))
    editMenu.addItem(withTitle: L("실행 취소", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
    let redo = editMenu.addItem(withTitle: L("다시 실행", "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: L("오려두기", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: L("복사하기", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: L("붙여넣기", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: L("모두 선택", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem(title: editMenu.title, action: nil, keyEquivalent: "")
    editItem.submenu = editMenu
    menu.addItem(editItem)
    return menu
}
