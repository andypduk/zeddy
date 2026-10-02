import SwiftUI
import ZeddyCore

/// Zeddy — manage the `~/.zeddy` memory store and the background daemon.
///
/// A full application-management GUI: add/edit/delete/inspect memories, run a
/// live context preview to see what Zed would inject (and how many tokens it
/// costs), and start/stop the daemon.
@main
struct ZeddyApp: App {
    @StateObject private var model = ZeddyModel()

    var body: some Scene {
        WindowGroup("Zeddy") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Memory…") { model.addMemory() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Button("Connect") { Task { await model.connect() } }
                Button("Disconnect") { model.disconnect() }
            }
        }
    }
}
