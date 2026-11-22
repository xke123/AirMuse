import AppKit

// Entry point – Swift 6 requires @main on a struct/class when using
// NSApplicationMain.  We use the manual approach so we can configure
// the process before the run-loop starts.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
