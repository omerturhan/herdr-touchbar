import AppKit

enum Log {
    private static let verbose = ["1", "true", "yes", "on"]
        .contains(ProcessInfo.processInfo.environment["HERDR_TOUCHBAR_DEBUG"]?.lowercased() ?? "")

    static func info(_ message: String) {
        FileHandle.standardError.write(Data("[herdr-touchbar] \(message)\n".utf8))
    }

    static func warn(_ message: String) { info("warning: \(message)") }

    static func debug(_ message: String) {
        guard verbose else { return }
        info(message)
    }
}

/// Raises the terminal that hosts the herdr session, so tapping an agent on the
/// Touch Bar actually puts it in front of the user.
enum TerminalActivator {

    /// Terminals we know how to raise, tried in order. Overridden entirely by
    /// `HERDR_TOUCHBAR_TERMINAL_BUNDLE_ID` when the guess is wrong.
    private static let candidates = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "dev.warp.Warp-Stable",
        "com.apple.Terminal",
    ]

    private static var preferred: [String] {
        let env = ProcessInfo.processInfo.environment["HERDR_TOUCHBAR_TERMINAL_BUNDLE_ID"]
        if let env, !env.isEmpty { return [env] }
        return candidates
    }

    static func activate() {
        for bundleId in preferred {
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleId).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
        Log.debug("no known terminal running; set HERDR_TOUCHBAR_TERMINAL_BUNDLE_ID")
    }
}
