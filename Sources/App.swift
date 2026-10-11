import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var insomnia: Insomnia!
    private var statusMenu: StatusMenu!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let snapshot = Snapshot.requested {
            insomnia = Insomnia(defaults: snapshot.defaults)
            statusMenu = StatusMenu(insomnia: insomnia)
            snapshot.run(statusMenu)
            return
        }
        #endif
        insomnia = Insomnia(defaults: .standard)
        statusMenu = StatusMenu(insomnia: insomnia)
    }

    func applicationWillTerminate(_ notification: Notification) {
        insomnia.shutDown()
    }
}
