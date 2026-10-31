import AddonKit
import SwiftUI

struct AddonsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var input = ""
    @State private var isInstalling = false
    @State private var error: String?

    var body: some View {
        @Bindable var app = app
        // Header and install field sit above the List: inside a List row, AppKit paints its own
        // rectangular field background inside the rounded glass box.
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(title: "Addons", subtitle: "\(app.addons.addons.count) installed") { controls }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("Paste an addon URL (https://… or stremio://…)", text: $input)
                        .textFieldStyle(.plain)
                        // The glass capsule is the field; no extra rectangle when it's focused.
                        .focusEffectDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                        .onSubmit(install)
                    if isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Install", action: install)
                            .buttonStyle(.glassProminent)
                            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)

            List {
                Section("Installed · drag to reorder (earlier addons answer first)") {
                    ForEach(app.addons.addons) { addon in
                        AddonRow(addon: addon) {
                            configure(addon)
                        }
                    }
                    .onMove { app.addons.move(fromOffsets: $0, toOffset: $1) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .pageScrollEdge()
        }
        .navigationTitle("Addons")
        .pageControls { controls }
        .onAppear(perform: consumePendingURL)
        .onChange(of: app.pendingAddonURL) { consumePendingURL() }
    }

    @ViewBuilder private var controls: some View {
        // Icon and text: toolbars would show these as bare icons.
        Button("Browse Community Addons", systemImage: "globe") {
            openURL(URL(string: "https://stremio-addons.net")!)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.glass)
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await app.addons.refreshManifests() }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.glass)
        .disabled(app.addons.isRefreshing)
    }

    private func consumePendingURL() {
        guard let url = app.pendingAddonURL else { return }
        app.pendingAddonURL = nil
        input = url
        install()
    }

    private func install() {
        let value = input
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isInstalling = true
        error = nil
        Task {
            defer { isInstalling = false }
            do {
                try await app.addons.install(value)
                input = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func configure(_ addon: InstalledAddon) {
        var string = addon.descriptor.transportUrl.absoluteString
        if string.hasSuffix("/manifest.json") { string.removeLast("manifest.json".count) }
        if let url = URL(string: string + "configure") { openURL(url) }
    }
}

private struct AddonRow: View {
    @Environment(AppModel.self) private var app
    var addon: InstalledAddon
    var onConfigure: () -> Void

    var body: some View {
        let manifest = addon.manifest
        HStack(spacing: 14) {
            RemoteImage(url: manifest.logo, contentMode: .fit)
                .frame(width: 44, height: 44)
                .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                .clipShape(.rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(manifest.name).font(.headline)
                    Text("v\(manifest.version)").font(.caption).foregroundStyle(.secondary)
                    if addon.descriptor.flags.official {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.blue).help("Official")
                    }
                }
                if let description = manifest.description {
                    Text(description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    ForEach(Array(Set(manifest.resources.map(\.name))).sorted(), id: \.self) { resource in
                        Text(resource)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.fill.secondary, in: .capsule)
                    }
                    Text(manifest.types.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if manifest.behaviorHints.configurable {
                Button("Configure", systemImage: "gearshape", action: onConfigure)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
            }
            Toggle("Enabled", isOn: Binding(get: { addon.isEnabled }, set: { app.addons.setEnabled(addon, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Copy URL", systemImage: "doc.on.doc") {
                Platform.copy(addon.descriptor.transportUrl.absoluteString)
            }
            if !addon.descriptor.flags.protected {
                Button("Uninstall", systemImage: "trash", role: .destructive) { app.addons.remove(addon) }
            }
        }
    }
}
