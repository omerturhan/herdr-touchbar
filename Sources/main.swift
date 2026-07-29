import AppKit

// Control signals can arrive as soon as the process appears in the process
// table. Ignore them from the start; TouchBarController replaces this with
// dispatch sources once the application has finished launching.
signal(SIGUSR1, SIG_IGN)
signal(SIGUSR2, SIG_IGN)

// SIGTERM/SIGINT would otherwise kill us outright, skipping
// applicationWillTerminate and stranding a presented system-modal Touch Bar that
// nothing else can dismiss. Catch them and shut down through AppKit instead.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = TouchBarController()
    private var terminationSources: [DispatchSourceSignal] = []
    private var readinessURL: URL {
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("HerdrTouchBar.ready")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            terminationSources.append(source)
        }

        controller.install()
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        do {
            try pid.write(to: readinessURL, atomically: true, encoding: .utf8)
        } catch {
            Log.warn("could not publish process readiness")
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        try? FileManager.default.removeItem(at: readinessURL)
        controller.uninstall()
    }
}

// Single-instance guard: relaunching should replace the running copy, not stack
// a second badge into the Control Strip.
let bundleId = Bundle.main.bundleIdentifier ?? "dev.herdr.touchbar"
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
for other in others {
    other.terminate()
}
if !others.isEmpty {
    // Give the outgoing instance a moment to pull its Control Strip item.
    Thread.sleep(forTimeInterval: 0.4)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
