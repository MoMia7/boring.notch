//
//  AgentAccessibility.swift
//  BoringNotchXPCHelper
//
//  Notch Agent: reads and presses menu-bar items of the frontmost app, and captures
//  what the user is looking at ("this"): selected text, window title, Finder selection,
//  browser page. Runs in the helper because sandboxed apps can't use Accessibility on
//  other apps.
//

import AppKit
import ApplicationServices
import Foundation

extension BoringNotchXPCHelper {

    // MARK: - Menu bar

    /// Items that are never offered, however well they match.
    private static let blockedMenuTitles: Set<String> = [
        "quit", "log out", "shut down", "restart", "sleep", "force quit", "delete", "move to trash",
        "erase", "empty trash", "sign out", "uninstall", "delete immediately", "secure empty trash",
    ]

    @objc func menuItems(processIdentifier: Int32, with reply: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.5)
            guard let menuBar: AXUIElement = Self.attribute(app, kAXMenuBarAttribute) else { return reply([]) }
            var paths: [String] = []
            let topItems: [AXUIElement] = Self.attribute(menuBar, kAXChildrenAttribute) ?? []
            // Skip the Apple menu (first item).
            for top in topItems.dropFirst() {
                guard let title: String = Self.attribute(top, kAXTitleAttribute), !title.isEmpty else { continue }
                Self.collect(top, path: [title], depth: 0, into: &paths)
                if paths.count > 600 { break }
            }
            reply(paths)
        }
    }

    private static func collect(_ element: AXUIElement, path: [String], depth: Int, into paths: inout [String]) {
        guard depth < 3 else { return }
        let menus: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        for menu in menus {
            let items: [AXUIElement] = attribute(menu, kAXChildrenAttribute) ?? []
            for item in items {
                guard let title: String = attribute(item, kAXTitleAttribute),
                      !title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if blockedMenuTitles.contains(title.lowercased().replacingOccurrences(of: "…", with: "")
                    .trimmingCharacters(in: .whitespaces)) || title.lowercased().hasPrefix("quit ") { continue }
                let enabled: Bool = attribute(item, kAXEnabledAttribute) ?? true
                let children: [AXUIElement] = attribute(item, kAXChildrenAttribute) ?? []
                if !children.isEmpty {
                    collect(item, path: path + [title], depth: depth + 1, into: &paths)
                } else if enabled {
                    paths.append((path + [title]).joined(separator: " › "))
                }
            }
        }
    }

    @objc func pressMenuItem(processIdentifier: Int32, path: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(app, 1)
            let parts = path.components(separatedBy: " › ")
            guard let menuBar: AXUIElement = Self.attribute(app, kAXMenuBarAttribute),
                  let target = Self.find(parts, under: menuBar) else { return reply(false) }
            // Bring the app forward so the command acts on its window.
            NSRunningApplication(processIdentifier: processIdentifier)?.activate()
            reply(AXUIElementPerformAction(target, kAXPressAction as CFString) == .success)
        }
    }

    private static func find(_ parts: [String], under element: AXUIElement) -> AXUIElement? {
        guard let first = parts.first else { return element }
        // Menu bar items and menu items are wrapped in AXMenu containers; search one level of those.
        var candidates: [AXUIElement] = attribute(element, kAXChildrenAttribute) ?? []
        if candidates.count == 1, (attribute(candidates[0], kAXRoleAttribute) as String?) == kAXMenuRole {
            candidates = attribute(candidates[0], kAXChildrenAttribute) ?? []
        }
        for candidate in candidates where (attribute(candidate, kAXTitleAttribute) as String?) == first {
            if parts.count == 1 { return candidate }
            return find(Array(parts.dropFirst()), under: candidate)
        }
        return nil
    }

    // MARK: - "This" context

    @objc func captureContext(processIdentifier: Int32, allowCopyFallback: Bool, with reply: @escaping (Data?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var context: [String: Any] = [:]
            let running = NSRunningApplication(processIdentifier: processIdentifier)
            let bundleID = running?.bundleIdentifier ?? ""
            context["app"] = running?.localizedName ?? ""
            context["bundleID"] = bundleID

            let app = AXUIElementCreateApplication(processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.4)
            // Chromium/Electron apps only expose their accessibility tree when asked.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let window: AXUIElement = Self.attribute(app, kAXFocusedWindowAttribute),
               let title: String = Self.attribute(window, kAXTitleAttribute), !title.isEmpty {
                context["windowTitle"] = title
            }
            var selected: String?
            if let focused: AXUIElement = Self.attribute(app, kAXFocusedUIElementAttribute),
               let text: String = Self.attribute(focused, kAXSelectedTextAttribute),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                selected = text
            }
            let isFinder = bundleID == "com.apple.finder"
            if selected == nil, allowCopyFallback, !isFinder {
                selected = Self.copySelection()
            }
            if let selected { context["selectedText"] = String(selected.prefix(8000)) }

            if isFinder, let paths = Self.appleScript("""
                tell application "Finder"
                  set out to ""
                  repeat with f in (get selection as alias list)
                    set out to out & POSIX path of f & linefeed
                  end repeat
                  return out
                end tell
                """) {
                let files = paths.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                if !files.isEmpty { context["finderSelection"] = Array(files.prefix(50)) }
            }
            if let script = Self.browserScript(for: bundleID), let result = Self.appleScript(script) {
                let parts = result.components(separatedBy: "\n")
                if let url = parts.first, url.hasPrefix("http") { context["pageURL"] = url }
                if parts.count > 1, !parts[1].isEmpty { context["pageTitle"] = parts[1] }
            }
            reply(try? JSONSerialization.data(withJSONObject: context))
        }
    }

    private static func browserScript(for bundleID: String) -> String? {
        switch bundleID {
        case "company.thebrowser.Browser":
            return #"tell application "Arc" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"#
        case "com.apple.Safari":
            return #"tell application "Safari" to return (URL of front document) & linefeed & (name of front document)"#
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac":
            let name = bundleID == "com.google.Chrome" ? "Google Chrome" : bundleID == "com.brave.Browser" ? "Brave Browser" : "Microsoft Edge"
            return "tell application \"\(name)\" to return (URL of active tab of front window) & linefeed & (title of active tab of front window)"
        default:
            return nil
        }
    }

    /// Fallback for apps that don't expose selected text: press ⌘C, read, restore the clipboard.
    private static func copySelection() -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        let saved = pasteboard.pasteboardItems?.map { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
            return copy
        } ?? []
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)  // "c"
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        var text: String?
        for _ in 0..<12 {  // up to ~240 ms
            Thread.sleep(forTimeInterval: 0.02)
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                break
            }
        }
        guard pasteboard.changeCount != before else { return nil }
        // Put the user's clipboard back.
        pasteboard.clearContents()
        let restored = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
        return text
    }

    private static func appleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result?.stringValue : nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        if T.self == [AXUIElement].self {
            return (value as? [AnyObject])?.compactMap { obj -> AXUIElement? in
                CFGetTypeID(obj) == AXUIElementGetTypeID() ? (obj as! AXUIElement) : nil
            } as? T
        }
        return value as? T
    }
}
