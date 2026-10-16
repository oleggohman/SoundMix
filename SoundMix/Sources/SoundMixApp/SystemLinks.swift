import AppKit
import Foundation

/// Shortcuts to the two system places you actually need while setting up a
/// downmix: where macOS picks its own output, and where device channel counts
/// and sample rates are configured.
enum SystemLinks {

    /// System Settings → Sound.
    static func openSoundSettings() {
        // Ventura and later use the Settings extension identifier; the older
        // preference pane is kept as a fallback for earlier systems.
        let candidates = [
            "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.sound",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        openApplication(at: "/System/Applications/System Settings.app")
    }

    /// System Settings → Privacy & Security → Microphone.
    static func openMicrophoneSettings() {
        MicrophoneAccess.openSettings()
    }

    /// Apple's Audio MIDI Setup, for channel counts, rates and aggregate devices.
    static func openAudioMIDISetup() {
        let paths = [
            "/System/Applications/Utilities/Audio MIDI Setup.app",
            "/Applications/Utilities/Audio MIDI Setup.app",
        ]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            openApplication(at: path)
            return
        }
        // Fall back to asking Launch Services to find it by bundle identifier.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.audio.AudioMIDISetup") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private static func openApplication(at path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
