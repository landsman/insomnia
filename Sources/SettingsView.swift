import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Opening at login, the apps that keep the Mac awake whenever they are open, and the bag safeguard.
struct SettingsView: View {
    let insomnia: Insomnia
    @State private var apps: [String]
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var watchesForBag: Bool

    init(insomnia: Insomnia) {
        self.insomnia = insomnia
        _apps = State(initialValue: insomnia.chosenApps)
        _watchesForBag = State(initialValue: insomnia.watchesForBag)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open at Login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, open in
                        let service = SMAppService.mainApp
                        try? open ? service.register() : service.unregister()
                        openAtLogin = service.status == .enabled
                    }
            }
            Section {
                ForEach(apps, id: \.self) { id in
                    AppRow(id: id) {
                        apps.removeAll { $0 == id }
                        insomnia.chosenApps = apps
                    }
                }
                Button(action: add) {
                    Label("Add App…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Keep Awake While Open")
            } footer: {
                Text("Your Mac stays awake while any of these apps is open.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Offered only on a MacBook with the motion sensor, without which a bag cannot be told;
            // anyone else learns why it is not there.
            Section {
                if BagSensors.hasMotionSensor {
                    Toggle("Sleep When Carried in a Bag", isOn: $watchesForBag)
                        .onChange(of: watchesForBag) { _, on in insomnia.watchesForBag = on }
                } else {
                    Text("“Sleep When Carried in a Bag” needs the motion sensor of a MacBook with M1 Pro, M1 Max, or M2 and later.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if BagSensors.hasMotionSensor {
                    Text("Close the lid and leave with your Mac, and it goes to sleep, safe in your bag. A walk to a meeting room keeps the work going.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        // Grows with the list, which scrolls once it is long.
        .frame(width: 440, height: CGFloat((BagSensors.hasMotionSensor ? 322 : 296) + 41 * min(apps.count, 8)))
    }

    private func add() {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            for id in panel.urls.compactMap({ Bundle(url: $0)?.bundleIdentifier }) where !apps.contains(id) {
                apps.append(id)
            }
            insomnia.chosenApps = apps
        }
    }
}

private struct AppRow: View {
    let id: String
    let remove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        HStack {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application))
                .resizable()
                .frame(width: 20, height: 20)
            Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? id)
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove")
        }
    }
}
