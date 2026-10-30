import Nuke
import SwiftUI

@main
struct VStreamApp: App {
    @State private var app = AppModel()

    init() {
        var configuration = ImagePipeline.Configuration.withDataCache(name: "com.vstream.images", sizeLimit: 512 << 20)
        configuration.isProgressiveDecodingEnabled = false
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
    }

    var body: some Scene {
        WindowGroup("VStream", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 620)
                .task { await app.start() }
                .onOpenURL { app.handle(url: $0) }
        }
        .defaultSize(width: 1360, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            CommandGroup(before: .sidebar) {
                Button("Search") {
                    app.path = []
                    app.selection = .search
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Refresh Addons") { Task { await app.addons.refreshManifests() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Play Link…") { app.showPlayLink() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Open Torrent File…") {
                    app.showPlayLink()
                    app.isImportingTorrent = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Sync Now") { Task { await app.stremio.sync() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Window("Player", id: "player") {
            PlayerWindow()
                .environment(app)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 720)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
