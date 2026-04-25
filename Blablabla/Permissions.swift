import Foundation
import AVFoundation
import ApplicationServices

enum Permissions {
    @discardableResult
    static func requestAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestMicrophone() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        default: return
        }
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
}
