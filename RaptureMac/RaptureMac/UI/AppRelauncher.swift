import AppKit

/// Quits and reopens the app. A running process never sees a Full Disk Access
/// grant made after it started, so after granting FDA the app must relaunch;
/// macOS sometimes offers "Quit & Reopen" itself, and when it doesn't (or the
/// user clicked "Later") this is the button that does it.
enum AppRelauncher {
    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The bundle path travels as $0, never spliced into the script text.
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
