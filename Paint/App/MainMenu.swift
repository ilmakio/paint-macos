import AppKit

/// Builds the menu bar in code — no nib, so every command and its shortcut is
/// visible in one place.
enum MainMenu {

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(imageMenu())
        main.addItem(colorsMenu())
        main.addItem(toolsMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        main.addItem(helpMenu())
        return main
    }

    // MARK: Helpers

    private static func submenu(_ title: String) -> (NSMenuItem, NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        return (item, menu)
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                            _ key: String = "",
                            modifiers: NSEvent.ModifierFlags = .command,
                            tag: Int = 0,
                            target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        item.target = target
        menu.addItem(item)
        return item
    }

    // MARK: Menus

    private static func appMenu() -> NSMenuItem {
        let (item, menu) = submenu("Paint")

        add(menu, "About Paint", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        add(menu, "Hide Paint", #selector(NSApplication.hide(_:)), "h")
        add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h",
            modifiers: [.command, .option])
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Quit Paint", #selector(NSApplication.terminate(_:)), "q")

        return item
    }

    private static func fileMenu() -> NSMenuItem {
        let (item, menu) = submenu("File")

        add(menu, "New", #selector(NSDocumentController.newDocument(_:)), "n")
        add(menu, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")

        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        // AppKit populates any menu carrying this identifier.
        recentMenu.identifier = NSUserInterfaceItemIdentifier("NSRecentDocumentsMenu")
        recentMenu.addItem(withTitle: "Clear Menu",
                           action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                           keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        add(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(menu, "Save", #selector(NSDocument.save(_:)), "s")
        add(menu, "Save As…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift])
        add(menu, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        menu.addItem(.separator())
        add(menu, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p",
            modifiers: [.command, .shift])
        add(menu, "Print…", #selector(NSDocument.printDocument(_:)), "p")

        return item
    }

    private static func editMenu() -> NSMenuItem {
        let (item, menu) = submenu("Edit")

        add(menu, "Undo", #selector(PaintWindowController.paintUndo(_:)), "z")
        add(menu, "Redo", #selector(PaintWindowController.paintRedo(_:)), "z",
            modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Cut", #selector(PaintWindowController.cut(_:)), "x")
        add(menu, "Copy", #selector(PaintWindowController.copy(_:)), "c")
        add(menu, "Paste", #selector(PaintWindowController.paste(_:)), "v")
        add(menu, "Delete", #selector(PaintWindowController.delete(_:)), "\u{8}", modifiers: [])
        menu.addItem(.separator())
        add(menu, "Select All", #selector(PaintWindowController.selectAll(_:)), "a")
        add(menu, "Deselect", #selector(PaintWindowController.clearSelection(_:)), "d",
            modifiers: [.command, .shift])
        add(menu, "Crop to Selection", #selector(PaintWindowController.cropToSelection(_:)), "x",
            modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Copy To…", #selector(PaintWindowController.copyTo(_:)))
        add(menu, "Paste From…", #selector(PaintWindowController.pasteFrom(_:)))

        return item
    }

    private static func imageMenu() -> NSMenuItem {
        let (item, menu) = submenu("Image")

        add(menu, "Flip Horizontal", #selector(PaintWindowController.flipHorizontal(_:)), "h",
            modifiers: [.command, .shift])
        add(menu, "Flip Vertical", #selector(PaintWindowController.flipVertical(_:)), "v",
            modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Rotate 90° Right", #selector(PaintWindowController.rotate90(_:)), "r")
        add(menu, "Rotate 90° Left", #selector(PaintWindowController.rotate270(_:)), "r",
            modifiers: [.command, .shift])
        add(menu, "Rotate 180°", #selector(PaintWindowController.rotate180(_:)))
        menu.addItem(.separator())
        add(menu, "Stretch and Skew…", #selector(PaintWindowController.stretchSkew(_:)))
        add(menu, "Invert Colors", #selector(PaintWindowController.invertColors(_:)), "i",
            modifiers: [.command, .shift])
        add(menu, "Attributes…", #selector(PaintWindowController.imageAttributes(_:)), "e")
        add(menu, "Clear Image", #selector(PaintWindowController.clearImage(_:)), "n",
            modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Draw Opaque", #selector(PaintWindowController.toggleDrawOpaque(_:)))

        return item
    }

    private static func colorsMenu() -> NSMenuItem {
        let (item, menu) = submenu("Colors")

        add(menu, "Edit Foreground Color…", #selector(PaintWindowController.editForegroundColor(_:)))
        add(menu, "Edit Background Color…", #selector(PaintWindowController.editBackgroundColor(_:)))
        menu.addItem(.separator())
        add(menu, "Swap Colors", #selector(PaintWindowController.swapColors(_:)), "x", modifiers: [])
        add(menu, "Default Colors", #selector(PaintWindowController.resetColors(_:)), "d", modifiers: [])
        menu.addItem(.separator())
        add(menu, "Reset Palette", #selector(PaintWindowController.resetPalette(_:)))

        return item
    }

    private static func toolsMenu() -> NSMenuItem {
        let (item, menu) = submenu("Tools")

        for kind in ToolKind.allCases {
            add(menu, kind.title, #selector(PaintWindowController.selectToolFromMenu(_:)),
                kind.shortcut, modifiers: [], tag: kind.rawValue)
        }
        menu.addItem(.separator())
        add(menu, "Increase Size", #selector(PaintWindowController.increaseToolSize(_:)), "]",
            modifiers: [])
        add(menu, "Decrease Size", #selector(PaintWindowController.decreaseToolSize(_:)), "[",
            modifiers: [])

        return item
    }

    private static func viewMenu() -> NSMenuItem {
        let (item, menu) = submenu("View")

        add(menu, "Zoom In", #selector(PaintWindowController.zoomIn(_:)), "+")
        add(menu, "Zoom Out", #selector(PaintWindowController.zoomOut(_:)), "-")
        add(menu, "Actual Size", #selector(PaintWindowController.zoomActualSize(_:)), "0")
        add(menu, "Fit to Window", #selector(PaintWindowController.zoomToFit(_:)), "9")
        menu.addItem(.separator())
        add(menu, "Show Grid", #selector(PaintWindowController.toggleGrid(_:)), "g",
            modifiers: [.command, .shift])
        menu.addItem(.separator())
        add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
            modifiers: [.command, .control])

        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let (item, menu) = submenu("Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenu() -> NSMenuItem {
        let (item, menu) = submenu("Help")
        add(menu, "Paint Shortcuts", #selector(AppDelegate.showShortcuts(_:)), "/",
            modifiers: [.command, .shift])
        NSApp.helpMenu = menu
        return item
    }
}
