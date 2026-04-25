import Foundation
import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyManager {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var modifierFlag: NSEvent.ModifierFlags = .option
    private var isHeld = false

    static let kModifierFlagDefaultsKey = "blabla.hotkey.modifier"

    func installFromDefaults() {
        let raw = UserDefaults.standard.integer(forKey: Self.kModifierFlagDefaultsKey)
        let flag: NSEvent.ModifierFlags = raw == 0
            ? .option
            : NSEvent.ModifierFlags(rawValue: UInt(raw))
        install(modifier: flag)
    }

    func install(modifier: NSEvent.ModifierFlags) {
        uninstall()
        modifierFlag = modifier
        UserDefaults.standard.set(Int(modifier.rawValue), forKey: Self.kModifierFlagDefaultsKey)

        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handle(event: event)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    func uninstall() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        isHeld = false
    }

    private func handle(event: NSEvent) {
        let pressed = event.modifierFlags.contains(modifierFlag)
            && Self.matchesExactly(event: event, modifier: modifierFlag)
        if pressed && !isHeld {
            isHeld = true
            onPress?()
        } else if !pressed && isHeld {
            isHeld = false
            onRelease?()
        }
    }

    /// Returns true if the only modifier currently down is `modifier`
    /// (we use raw key codes for left/right disambiguation).
    private static func matchesExactly(event: NSEvent, modifier: NSEvent.ModifierFlags) -> Bool {
        let device = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Allow caps lock to coexist
        let cleaned = device.subtracting(.capsLock)
        return cleaned == modifier
    }

    static func displayName(for modifier: NSEvent.ModifierFlags) -> String {
        switch modifier {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        case .shift: return "⇧ Shift"
        case .function: return "fn"
        default: return "Custom"
        }
    }
}
