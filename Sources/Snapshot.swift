#if DEBUG
import AppKit

/// INSOMNIA_SNAPSHOT=/tmp/shot opens the menu, saves /tmp/shot-menu.png and /tmp/shot-icon.png, and quits.
/// INSOMNIA_ON=1, INSOMNIA_MODE=always, INSOMNIA_DARK=1 and INSOMNIA_HIGHLIGHT=<row title> set up what to capture.
@MainActor
struct Snapshot {
    let path: String
    let defaults: UserDefaults

    static var requested: Snapshot? {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["INSOMNIA_SNAPSHOT"],
              let defaults = UserDefaults(suiteName: "com.michalptacek.insomnia.snapshot") else { return nil }
        defaults.set(environment["INSOMNIA_ON"] == "1", forKey: "on")
        defaults.set(environment["INSOMNIA_MODE"] ?? "agents", forKey: "mode")
        return Snapshot(path: path, defaults: defaults)
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
            statusMenu.statusItem.button?.performClick(nil)
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
                  let image = capture(.null, 1 << 3, id, 1 << 3)?.takeRetainedValue() else { continue }
            let name = layer == CGWindowLevelForKey(.statusWindow) ? "icon" : "menu"
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try? data?.write(to: URL(fileURLWithPath: "\(path)-\(name).png"))
        }
    }
}
#endif
