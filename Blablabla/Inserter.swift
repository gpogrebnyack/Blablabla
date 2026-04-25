import Foundation
import AppKit
import ApplicationServices
import OSLog

@MainActor
final class Inserter {
    private let log = Logger(subsystem: "blablabla", category: "insert")

    /// Apps where AX text insertion silently no-ops (or worse, returns success but
    /// doesn't actually write anything). For these we go straight to clipboard+Cmd+V.
    private static let pasteOnlyBundleIDs: Set<String> = [
        // Terminals
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "app.warp.Warp",
        "co.zeit.hyper",
        "io.alacritty",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "com.tabby.app",
        "com.github.wez.wezterm",
        // Telegram — custom text view, AX setSelectedText is a no-op.
        "ru.keepcoder.Telegram",
        "com.tdesktop.Telegram",
    ]

    /// Returns true when the frontmost app is in our known "AX-hostile" list.
    static func shouldSkipAXForFrontmostApp() -> Bool {
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return pasteOnlyBundleIDs.contains(bid)
    }

    /// Snapshots the currently focused element (called when recording starts so we
    /// don't pay for the AX query after generation finishes).
    func captureFocus() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let elem = focused else { return nil }
        return (elem as! AXUIElement)
    }

    /// Tries AX path first, falls back to pasteboard + Cmd+V.
    func insert(_ text: String, into element: AXUIElement?) {
        if !AXIsProcessTrusted() {
            log.error("Accessibility NOT granted — both AX and CGEvent paste will fail. Grant in System Settings → Privacy & Security → Accessibility, then restart the app.")
        }
        if Self.shouldSkipAXForFrontmostApp() {
            log.info("Terminal-class app frontmost — using paste path directly")
            pasteFallback(text)
            return
        }
        if let elem = element, axInsert(text, into: elem) {
            log.info("inserted via AX")
            return
        }
        log.info("AX failed or no focus captured — paste fallback")
        pasteFallback(text)
    }

    /// Begin a streaming insert: each `append(_:)` writes a chunk at the cursor.
    /// On AX failure, accumulates the rest and pastes once on `finish()`.
    func beginStream(into element: AXUIElement?) -> StreamingSession {
        if !AXIsProcessTrusted() {
            log.error("Accessibility NOT granted — streaming insert will fall back to clipboard.")
        }
        // Force paste mode for AX-hostile apps (terminals) by passing nil target;
        // the session will accumulate chunks and paste once on finish().
        let target = Self.shouldSkipAXForFrontmostApp() ? nil : element
        if target == nil && element != nil {
            log.info("Terminal-class app frontmost — streaming will accumulate and paste at end")
        }
        return StreamingSession(target: target, log: log) { [weak self] text in
            self?.pasteFallback(text)
        }
    }

    private func axInsert(_ text: String, into elem: AXUIElement) -> Bool {
        let selErr = AXUIElementSetAttributeValue(
            elem,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        if selErr == .success { return true }
        log.debug("AX kAXSelectedTextAttribute failed: \(selErr.rawValue)")

        var current: CFTypeRef?
        let copyErr = AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &current)
        if copyErr == .success, let s = current as? String {
            let combined = s + text
            let setErr = AXUIElementSetAttributeValue(elem, kAXValueAttribute as CFString, combined as CFString)
            if setErr == .success { return true }
            log.debug("AX kAXValueAttribute set failed: \(setErr.rawValue)")
        } else {
            log.debug("AX kAXValueAttribute copy failed: \(copyErr.rawValue)")
        }
        return false
    }

    private func pasteFallback(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        } ?? []

        pb.clearContents()
        let writeOK = pb.setString(text, forType: .string)
        log.info("pasteboard write: \(writeOK), text length=\(text.count)")

        // Give the OS a beat to settle any lingering modifier state from the hotkey release.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.sendCmdV()
        }

        // Restore previous pasteboard after the paste has had time to land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            for entry in saved {
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                pb.writeObjects([item])
            }
        }
    }

    private func sendCmdV() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else {
            log.error("CGEventSource creation failed")
            return
        }
        let vKey: CGKeyCode = 9 // 'v'
        // Press Command first, then V, then release in reverse — mirrors a real keystroke
        // and is more compatible with Electron / sandboxed apps that watch flagsChanged.
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x37 /* left command */, keyDown: true)
        cmdDown?.flags = .maskCommand
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x37, keyDown: false)
        cmdUp?.flags = []

        let tap: CGEventTapLocation = .cghidEventTap
        cmdDown?.post(tap: tap)
        vDown?.post(tap: tap)
        vUp?.post(tap: tap)
        cmdUp?.post(tap: tap)

        if cmdDown == nil || vDown == nil { log.error("CGEvent build failed") }
    }
}

/// Per-utterance streaming inserter. Tries AX for each chunk; on first AX failure
/// switches to paste-accumulation mode and commits the buffered text once on `finish()`.
@MainActor
final class StreamingSession {
    typealias PasteHandler = (String) -> Void

    private let log: Logger
    private let target: AXUIElement?
    private let paste: PasteHandler
    private var failedAX = false
    private var pasteAccum = ""
    private var emitted = 0

    fileprivate init(target: AXUIElement?, log: Logger, paste: @escaping PasteHandler) {
        self.target = target
        self.log = log
        self.paste = paste
        if target == nil { failedAX = true }
    }

    /// Insert one chunk at the current cursor (or accumulate for paste fallback).
    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        emitted += chunk.count
        if failedAX {
            pasteAccum += chunk
            return
        }
        let err = AXUIElementSetAttributeValue(
            target!, kAXSelectedTextAttribute as CFString, chunk as CFString
        )
        if err != .success {
            log.debug("AX streaming chunk failed (\(err.rawValue)) — switching to paste accumulation")
            failedAX = true
            pasteAccum = chunk  // chunk that just failed
        }
    }

    /// Commit. If we fell back to paste, perform one paste with the accumulated text.
    func finish() {
        if failedAX && !pasteAccum.isEmpty {
            paste(pasteAccum)
            log.info("inserted via paste fallback (streaming, \(self.emitted) chars total)")
        } else if !failedAX && emitted > 0 {
            log.info("inserted via AX streaming (\(self.emitted) chars)")
        }
    }
}
