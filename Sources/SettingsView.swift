import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Opening at login, and the apps that keep the Mac awake whenever they are open.
struct SettingsView: View {
    let insomnia: Insomnia
    @State private var apps: [String]
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    init(insomnia: Insomnia) {
        self.insomnia = insomnia
        _apps = State(initialValue: insomnia.chosenApps)
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
        }
        .formStyle(.grouped)
        // Grows with the list, which scrolls once it is long.
        .frame(width: 440, height: CGFloat(212 + 41 * min(apps.count, 8)))
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
