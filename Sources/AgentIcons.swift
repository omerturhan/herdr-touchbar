import AppKit

/// Resolves an agent name to a Touch Bar sized icon.
///
/// Known agents get their real brand mark (vendored from lobe-icons); anything
/// else falls back to a generated tile so a new agent still looks deliberate.
enum AgentIcons {

    private static var cache: [String: NSImage] = [:]

    /// herdr agent id -> bundled PNG basename.
    private static let files: [String: String] = [
        "opencode": "opencode",
        "gemini": "gemini-color",
        "geminicli": "geminicli-color",
        "cursor": "cursor",
        "copilot": "copilot-color",
        "githubcopilot": "githubcopilot",
        "grok": "grok",
        "kimi": "kimi-color",
        "qwen": "qwen-color",
        "deepseek": "deepseek-color",
        "openai": "openai",
        "windsurf": "windsurf",
        "cline": "cline",
        "roocode": "roocode",
        "trae": "trae-color",
        "kiro": "kiro-color",
    ]

    /// Brand assets whose runtime ids should not be persisted in repository text.
    private static let privateFiles: [UInt64: String] = [
        0x2ffb778dfae54384: "agent-mark-01",
        0x239194803edf98f7: "agent-mark-02",
        0x7254a0fa1bdd2396: "agent-mark-02",
    ]

    /// Agents with no brand asset but a recognisable glyph of their own.
    private static let glyphs: [String: String] = [
        "omp": "π",
        "pi": "π",
        "agy": "◈",
        "amp": "≋",
    ]

    /// Stable fallback tints, picked by hashing the agent name.
    private static let palette: [NSColor] = [
        .systemTeal, .systemPurple, .systemPink, .systemIndigo,
        .systemBrown, .systemBlue, .systemYellow,
    ]

    static func icon(for agent: String, size: CGFloat = 18) -> NSImage {
        let key = "\(agent)@\(size)"
        if let hit = cache[key] { return hit }

        let image = load(agent: agent, size: size) ?? generated(agent: agent, size: size)
        image.size = NSSize(width: size, height: size)
        cache[key] = image
        return image
    }

    private static func load(agent: String, size: CGFloat) -> NSImage? {
        let normalizedAgent = agent.lowercased()
        guard let name = files[normalizedAgent] ?? privateFiles[stableKey(normalizedAgent)],
              let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "agents")
                ?? Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        return image
    }

    private static func stableKey(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    /// Rounded tile with the agent's glyph — used for agents we ship no art for.
    private static func generated(agent: String, size: CGFloat) -> NSImage {
        let glyph = glyphs[agent] ?? String(agent.prefix(1)).uppercased()
        let paletteIndex = Int(UInt(bitPattern: agent.hashValue) % UInt(palette.count))
        let tint = palette[paletteIndex]

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: size * 0.28, yRadius: size * 0.28)
        tint.withAlphaComponent(0.9).setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.62, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = glyph as NSString
        let textSize = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (size - textSize.width) / 2,
                              y: (size - textSize.height) / 2),
                  withAttributes: attrs)
        image.unlockFocus()
        return image
    }
}

/// Colours for each agent state, tuned to read at a glance on the Touch Bar.
enum StatusPalette {
    static func bezel(for status: AgentStatus) -> NSColor {
        switch status {
        case .blocked: return NSColor.systemRed
        case .working: return NSColor.systemOrange
        case .done:    return NSColor.systemGreen
        case .idle:    return NSColor(white: 0.22, alpha: 1.0)
        case .unknown: return NSColor(white: 0.16, alpha: 1.0)
        }
    }

    static func text(for status: AgentStatus) -> NSColor {
        switch status {
        case .blocked, .working, .done: return .white
        case .idle:    return NSColor(white: 0.78, alpha: 1.0)
        case .unknown: return NSColor(white: 0.55, alpha: 1.0)
        }
    }
}

/// Braille spinner — the "it's running" animation next to busy agents.
enum Spinner {
    static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    static let interval: TimeInterval = 0.25

    static func frame(_ tick: Int) -> String { frames[tick % frames.count] }
}
