import AppKit

// No storyboard: the menu bar and every window are built in code, so the
// entry point stays this small.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)
application.run()
