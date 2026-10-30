import DebridKit
import PlayerKit
import SwiftUI
import TorrentKit
import VStreamCore

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Accounts", systemImage: "person.crop.circle") { AccountsSettings() }
            Tab("Debrid", systemImage: "bolt") { DebridSettings() }
            Tab("Playback", systemImage: "play.rectangle") { PlaybackSettings() }
            Tab("Torrent", systemImage: "point.3.connected.trianglepath.dotted") { TorrentSettingsView() }
        }
        .frame(width: 560, height: 480)
        .scenePadding()
    }
}

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var error: String?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Stremio") {
                if let session = app.stremio.session {
                    LabeledContent("Signed in as", value: session.user.email)
                    if let lastSync = app.stremio.lastSync {
                        LabeledContent("Last sync", value: lastSync.formatted(.relative(presentation: .named)))
                    }
                    if let error = app.stremio.lastError { Text(error).foregroundStyle(.red).font(.caption) }
                    HStack {
                        Button("Sync Now") { Task { await app.stremio.sync() } }.disabled(app.stremio.isSyncing)
                        Spacer()
                        Button("Sign Out", role: .destructive) { Task { await app.stremio.signOut() } }
                    }
                } else {
                    TextField("Email", text: $email).textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    HStack {
                        Text("Syncs your addons, library and watch progress.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign In") {
                            isSigningIn = true
                            error = nil
                            Task {
                                defer { isSigningIn = false }
                                do {
                                    try await app.stremio.signIn(email: email, password: password)
                                    password = ""
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(email.isEmpty || password.isEmpty || isSigningIn)
                    }
                }
            }

            Section {
                if app.trakt.isConnected {
                    LabeledContent("Status", value: "Connected")
                    HStack {
                        Button("Import History") { Task { await app.trakt.importHistory() } }.disabled(app.trakt.isSyncing)
                        Spacer()
                        Button("Disconnect", role: .destructive) { Task { await app.trakt.disconnect() } }
                    }
                } else if app.trakt.isWaitingForBrowser {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Approve VStream in your browser…")
                        Spacer()
                        Button("Cancel") { app.trakt.cancelConnect() }
                    }
                } else {
                    TextField("Client ID", text: $settings.settings.traktClientID)
                        .onChange(of: settings.settings.traktClientID) { app.trakt.credentialsChanged() }
                    HStack {
                        Link("Create a Trakt API app", destination: URL(string: "https://trakt.tv/oauth/applications/new")!)
                            .font(.caption)
                        Spacer()
                        Button("Connect") {
                            app.trakt.connect { url in
                                await MainActor.run { _ = NSWorkspace.shared.open(url) }
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(!app.trakt.hasCredentials)
                    }
                }
                if let error = app.trakt.lastError { Text(error).foregroundStyle(.red).font(.caption) }
            } header: {
                Text("Trakt")
            } footer: {
                Text("Set the Trakt app’s redirect URI to “http://localhost:8765/trakt”.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DebridSettings: View {
    @Environment(AppModel.self) private var app
    @State private var status: String?
    @State private var isChecking = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Service", selection: Binding(get: { settings.settings.debridService }, set: { settings.selectDebrid($0); status = nil })) {
                    Text("None").tag(DebridService?.none)
                    ForEach(DebridService.allCases) { Text($0.displayName).tag(Optional($0)) }
                }
                if let service = settings.settings.debridService {
                    SecureField("API Key", text: $settings.debridAPIKey)
                    HStack {
                        Link("Get your \(service.displayName) API key", destination: service.apiKeyPage).font(.caption)
                        Spacer()
                        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                        Button("Verify") { verify() }.disabled(settings.debridAPIKey.isEmpty || isChecking)
                    }
                }
            } footer: {
                Text("Torrent streams are resolved to fast HTTP links through your debrid account when cached.")
            }
            Section("Torrent streams") {
                Picker("Play torrents with", selection: $settings.settings.torrentMode) {
                    ForEach(TorrentMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }

    private func verify() {
        guard let provider = app.settings.debridProvider else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                status = try await provider.validate() ? "✓ Key works" : "Key rejected"
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("Player") {
                Toggle("Hardware decoding (VideoToolbox)", isOn: $settings.settings.hardwareDecoding)
                Toggle("Play next episode automatically", isOn: $settings.settings.autoplayNextEpisode)
                Toggle("Show adult catalogs", isOn: $settings.settings.showAdultCatalogs)
            }
            Section {
                Picker("Default audio language", selection: language(\.preferredAudioLanguages)) {
                    Text("File default").tag(String?.none)
                    Divider()
                    ForEach(Languages.all) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Default subtitles", selection: language(\.preferredSubtitleLanguages)) {
                    Text("Off").tag(String?.none)
                    Divider()
                    ForEach(Languages.all) { Text($0.name).tag(Optional($0.id)) }
                }
            } header: {
                Text("Languages")
            } footer: {
                Text("Picked automatically when a video starts, from the file's tracks or your subtitle addons.")
            }
            Section("Subtitle style") {
                Slider(value: $settings.settings.subtitleStyle.fontSize, in: 24...80, step: 2) { Text("Size") }
                Slider(value: $settings.settings.subtitleStyle.position, in: 70...100, step: 1) { Text("Position") }
                Slider(value: $settings.settings.subtitleStyle.backgroundOpacity, in: 0...1) { Text("Background") }
                Slider(value: $settings.settings.subtitleStyle.borderSize, in: 0...6, step: 0.5) { Text("Outline") }
                Toggle("Bold", isOn: $settings.settings.subtitleStyle.bold)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.settings.subtitleStyle) { _, style in
            app.playback?.player.apply(style)
        }
    }

    /// Settings store every code variant of the language so mpv's alang/slang and addon
    /// subtitles match however they spell it.
    private func language(_ keyPath: WritableKeyPath<AppSettings, [String]>) -> Binding<String?> {
        Binding(
            get: { Languages.option(for: app.settings.settings[keyPath: keyPath].first)?.id },
            set: { id in
                app.settings.settings[keyPath: keyPath] = Languages.all.first { $0.id == id }?.codes ?? []
            }
        )
    }

}

private struct TorrentSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var cleared = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Profile", selection: $settings.settings.torrent.profile) {
                    Text("Gentle").tag(TorrentSettings.Profile.soft)
                    Text("Balanced").tag(TorrentSettings.Profile.balanced)
                    Text("Fast").tag(TorrentSettings.Profile.fast)
                }
                .pickerStyle(.segmented)
                Stepper("Disk cache: \(settings.settings.torrent.diskCacheGB) GB", value: $settings.settings.torrent.diskCacheGB, in: 1...50)
                Toggle("Upload while streaming", isOn: $settings.settings.torrent.uploadEnabled)
            } footer: {
                Text("Powered by nuvio-engine \(TorrentStreamer.version) (libtorrent).")
            }
            Section {
                Button(cleared ? "Cache cleared" : "Clear torrent cache") {
                    Task {
                        try? await TorrentStreamer.shared.clearCache()
                        cleared = true
                    }
                }
                .disabled(cleared)
            }
        }
        .formStyle(.grouped)
    }
}
