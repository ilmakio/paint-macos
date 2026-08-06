import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // Silent unless there is something newer, and no more than once a day.
        UpdateChecker.shared.checkInBackgroundIfDue()
    }

    // MARK: Updates

    @objc func toggleAutomaticUpdateChecks(_ sender: Any?) {
        UpdateChecker.shared.checksAutomatically.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticUpdateChecks(_:)) {
            menuItem.state = UpdateChecker.shared.checksAutomatically ? .on : .off
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: Help

    @objc func showShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = AppDelegate.shortcutsText
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    private static let shortcutsText = """
    TOOLS
      P pencil · B brush · E eraser · F fill · A airbrush
      I pick colour · Z magnifier · T text
      L line · C curve · R rectangle · G polygon
      O ellipse · U rounded rectangle
      M rectangular select · S free-form select
      [ / ]  shrink or grow the nib

    COLOURS
      Left click paints with the foreground colour, right click with the background.
      Click a swatch to set the foreground, right-click for the background,
      double-click to redefine it.
      X swaps the two colours · D restores black and white.

    CANVAS
      Space-drag pans · pinch or ⌘+ / ⌘− zooms · ⌘0 actual size · ⌘9 fit
      Drag the white grips on the right and bottom edges to resize the canvas.

    WHILE DRAWING
      Shift constrains lines to 45° and shapes to squares and circles.
      Esc abandons the shape in progress; Return closes a polygon or curve.

    SELECTIONS
      Drag inside to move · Option-drag to leave a copy behind
      Drag a handle to stretch · arrows nudge · Delete clears
    """
}
