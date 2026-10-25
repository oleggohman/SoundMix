import SwiftUI
import AppKit
import Sparkle

struct SoundMixApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The app's one Sparkle updater, started at launch. It runs the daily
    /// background check on its own and installs only after the user agrees
    /// (see the SU* keys in Info.plist).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        Window("SoundMix", id: "main") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .onAppear { model.reloadPEQWarnings() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandMenu("Render") {
                Button("Start") { model.start() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.state.isRunning || model.startBlockedReason != nil)
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!model.state.isRunning)
                Divider()
                // ⌘S is Save everywhere on macOS: it persists the profile too,
                // not just the engine push.
                Button("Apply") { model.applyAndSavePEQ() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(!model.state.isRunning)
                Divider()
                Button("Rescan Audio Devices") { model.refreshDevices() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

SoundMixApp.main()
