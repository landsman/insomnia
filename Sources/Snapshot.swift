#if DEBUG
import AppKit

/// INSOMNIA_SNAPSHOT=/tmp/shot opens the menu, saves /tmp/shot-menu.png and /tmp/shot-icon.png, and quits.
/// With INSOMNIA_SETTINGS=1 it shows the settings window instead, with INSOMNIA_CHOSEN="bundle.id,…" in it,
/// and with INSOMNIA_ABOUT=1 the About panel.
/// INSOMNIA_ON=1, INSOMNIA_MODE=always, INSOMNIA_DARK=1 and INSOMNIA_HIGHLIGHT=<row title> set up what to capture.
/// INSOMNIA_AGENTS="project:Agent,…", INSOMNIA_APPS="/Applications/App.app,…" and INSOMNIA_UPLOAD=<bytes per second>
/// show that work instead of whatever runs on this Mac.
@MainActor
struct Snapshot {
    let path: String
    let defaults: UserDefaults
    let demo: (agents: [Agent], apps: [BusyApp], upload: Double)?

    static var requested: Snapshot? {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["INSOMNIA_SNAPSHOT"],
              let defaults = UserDefaults(suiteName: "com.michalptacek.insomnia.snapshot") else { return nil }
        defaults.set(environment["INSOMNIA_ON"] == "1", forKey: "on")
        defaults.set(environment["INSOMNIA_MODE"] ?? "agents", forKey: "mode")
        defaults.set((environment["INSOMNIA_CHOSEN"] ?? "").split(separator: ",").map(String.init), forKey: "chosenApps")
        let agents = (environment["INSOMNIA_AGENTS"] ?? "").split(separator: ",").enumerated().map { index, entry in
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            return Agent(pid: pid_t(index + 1), name: parts.last ?? "", project: parts.first ?? "", isWorking: true)
        }
        let apps = (environment["INSOMNIA_APPS"] ?? "").split(separator: ",").map {
            BusyApp(name: FileManager.default.displayName(atPath: String($0)), bundle: String($0))
        }
        let upload = Double(environment["INSOMNIA_UPLOAD"] ?? "") ?? 0
        let demo = agents.isEmpty && apps.isEmpty && upload == 0 ? nil : (agents, apps, upload)
        return Snapshot(path: path, defaults: defaults, demo: demo)
    }

    func run(_ statusMenu: StatusMenu) {
        if ProcessInfo.processInfo.environment["INSOMNIA_DARK"] == "1" {
            statusMenu.menu.appearance = NSAppearance(named: .darkAqua)
        }
        after(1.5) {
            after(1) {
                save()
                statusMenu.menu.cancelTracking()
                RunLoop.main.perform(inModes: [.default]) {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                }
            }
            // Windows come to the front without taking focus from whatever is in use.
            if ProcessInfo.processInfo.environment["INSOMNIA_SETTINGS"] == "1" {
                statusMenu.settings.orderFrontRegardless()
            } else if ProcessInfo.processInfo.environment["INSOMNIA_ABOUT"] == "1" {
                NSApp.orderFrontStandardAboutPanel(options: [.credits: StatusMenu.credits])
            } else {
                statusMenu.statusItem.button?.performClick(nil)
            }
        }
    }

    private func after(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated(action) }
        RunLoop.main.add(timer, forMode: .common)
    }

    private typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage is gone from the SDK but still captures the app's own windows
    /// without Screen Recording permission.
    private func save() {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage"),
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        for window in windows where window[kCGWindowOwnerPID as String] as? Int32 == getpid() {
            guard let id = window[kCGWindowNumber as String] as? UInt32,
                  let layer = window[kCGWindowLayer as String] as? Int32,
                  // Menus only come out on external displays without their frame and shadow; windows only with them.
                  let image = capture(.null, 1 << 3, id, layer == 0 ? 1 << 3 : 1 << 0 | 1 << 3)?.takeRetainedValue() else { continue }
            let name = layer == CGWindowLevelForKey(.statusWindow) ? "icon" : layer == 0 ? "window" : "menu"
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try? data?.write(to: URL(fileURLWithPath: "\(path)-\(name).png"))
        }
    }
}
#endif
