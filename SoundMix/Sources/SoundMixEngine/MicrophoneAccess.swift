import Foundation
import AVFoundation
import AppKit

/// macOS treats every audio input device as a microphone, so opening even a
/// virtual 16-channel loopback needs the microphone entitlement to be granted.
/// Without this the capture unit blocks and the app looks hung.
public enum MicrophoneAccess {

    public enum Status: Equatable, Sendable {
        case authorized
        case denied
        case restricted
        case notDetermined

        public var canCapture: Bool { self == .authorized }
    }

    public static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .notDetermined
        }
    }

    /// Asks for access when the user has not decided yet, then reports the result.
    public static func request(_ completion: @escaping (Status) -> Void) {
        switch status {
        case .authorized, .denied, .restricted:
            completion(status)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted ? .authorized : .denied) }
            }
        }
    }

    public static func explanation(for status: Status) -> String? {
        switch status {
        case .authorized:
            return nil
        case .notDetermined:
            return "macOS has not been asked for microphone access yet. Press Start and approve the prompt — audio input devices need it even when the source is a virtual loopback."
        case .denied:
            return "Microphone access is turned off for SoundMix, so no input device can be opened. Turn it on in System Settings → Privacy & Security → Microphone, then press Start again."
        case .restricted:
            return "Microphone access is restricted by a system policy and cannot be enabled from inside the app. A device-management profile or Screen Time restriction is blocking it."
        }
    }

    /// Opens the Microphone pane of System Settings.
    public static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
