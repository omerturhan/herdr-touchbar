import AppKit

/// Settings lookup, in priority order: the process environment, then a `.env`
/// file in the plugin's herdr config directory.
///
/// The file matters because the app is launched with `open`, and LaunchServices
/// does not hand a launched app the environment of whatever asked for it — so
/// exporting a variable in a shell could never reach us. The config directory is
/// the same one `herdr plugin config-dir herdr-touchbar` prints.
///
/// Deliberately does not use `Log`: `Log` reads its own setting from here.
enum Config {

    private static let fileValues: [String: String] = loadEnvFile()

    static func string(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty { return value }
        if let value = fileValues[key], !value.isEmpty { return value }
        return nil
    }

    static func flag(_ key: String) -> Bool {
        ["1", "true", "yes", "on"].contains(string(key)?.lowercased() ?? "")
    }

    static var configDirectory: String {
        if let dir = ProcessInfo.processInfo.environment["HERDR_PLUGIN_CONFIG_DIR"], !dir.isEmpty {
            return dir
        }
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (config as NSString).appendingPathComponent("herdr/plugins/config/herdr-touchbar")
    }

    /// Minimal `KEY=value` reader: tolerates `export`, surrounding quotes,
    /// comments and blank lines. No interpolation.
    private static func loadEnvFile() -> [String: String] {
        let path = (configDirectory as NSString).appendingPathComponent(".env")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }

        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }

            guard let split = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<split].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'",
               value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }
}

/// How the agent list is ordered.
enum SortMode: String {
    /// Grouped by space, in the arrangement the sidebar shows.
    case spaces
    /// Attention queue: whoever is waiting on you comes first.
    case priority
}

/// Follows herdr's own `ui.agent_panel_sort`, so the Touch Bar is ordered the
/// same way as the sidebar it sits under rather than having a second opinion.
///
/// Read from `config.toml` directly because the socket API does not expose UI
/// settings. Re-read when the file changes so toggling the setting in herdr does
/// not need the app restarted.
enum HerdrConfig {

    private static var cached: (mode: SortMode, stamp: Date)?
    private static let lock = NSLock()

    static var sortMode: SortMode {
        if let override = Config.string("HERDR_TOUCHBAR_SORT"),
           let mode = SortMode(rawValue: override.lowercased()) {
            return mode
        }

        lock.lock()
        defer { lock.unlock() }

        let path = configPath
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate])
            as? Date
        if let cached, cached.stamp == stamp { return cached.mode }

        let mode = parseSortMode(path) ?? .spaces
        cached = (mode, stamp ?? .distantPast)
        return mode
    }

    private static var configPath: String {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (config as NSString).appendingPathComponent("herdr/config.toml")
    }

    /// Scans the `[ui]` table for `agent_panel_sort`. Deliberately not a TOML
    /// parser — one key from one table, and being wrong just means falling back
    /// to the documented default.
    private static func parseSortMode(_ path: String) -> SortMode? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        var inUITable = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                // Nested tables such as [ui.sidebar.agents] are not the [ui] table.
                inUITable = (line == "[ui]")
                continue
            }
            guard inUITable, line.hasPrefix("agent_panel_sort") else { continue }
            guard let split = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: split)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
            // herdr accepts "workspaces" as an alias for "spaces".
            if value == "workspaces" { return .spaces }
            return SortMode(rawValue: value)
        }
        return nil
    }
}

enum Log {
    private static let verbose = Config.flag("HERDR_TOUCHBAR_DEBUG")

    /// Launched through `open`, the app has no useful stderr, so everything also
    /// goes to the standard user log location where it can actually be read.
    private static let file: FileHandle? = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs")
        let path = (dir as NSString).appendingPathComponent("herdr-touchbar.log")
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }()

    private static let lock = NSLock()

    static func info(_ message: String) {
        let line = Data("[herdr-touchbar] \(message)\n".utf8)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write(line)
        file?.write(line)
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
        if let configured = Config.string("HERDR_TOUCHBAR_TERMINAL_BUNDLE_ID") { return [configured] }
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
