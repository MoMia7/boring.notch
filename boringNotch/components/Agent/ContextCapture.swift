//
//  ContextCapture.swift
//  boringNotch
//
//  "This" context and menu-bar commands of the app the user is working in. Capture starts
//  the moment push-to-talk is pressed (before anything changes focus) and runs alongside
//  speech recognition; routing waits for it only briefly.
//

import AppKit
import Foundation

struct ScreenContext: Equatable {
    var app: String?
    var bundleID: String?
    var windowTitle: String?
    var selectedText: String?
    var finderSelection: [String] = []
    var pageURL: String?
    var pageTitle: String?
    var capturedAt = Date()

    init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        app = json["app"] as? String
        bundleID = json["bundleID"] as? String
        windowTitle = json["windowTitle"] as? String
        selectedText = json["selectedText"] as? String
        finderSelection = json["finderSelection"] as? [String] ?? []
        pageURL = json["pageURL"] as? String
        pageTitle = json["pageTitle"] as? String
    }

    var hasReferent: Bool { selectedText != nil || !finderSelection.isEmpty || pageURL != nil }

    /// Metadata only, for Jev (never the selected text or file names).
    var jevSummary: [String: Any] {
        [
            "front_app": app ?? "unknown",
            "has_selected_text": selectedText != nil,
            "selected_text_length": selectedText?.count ?? 0,
            "finder_selected_files": finderSelection.count,
            "has_web_page": pageURL != nil,
        ]
    }

    /// Prepended to agent prompts that refer to "this".
    func promptBlock(focus: String?) -> String {
        var lines = ["[What the user was looking at when they asked]"]
        if let app { lines.append("App: \(app)" + (windowTitle.map { " — window “\($0)”" } ?? "")) }
        if let pageURL { lines.append("Web page: \(pageURL)" + (pageTitle.map { " (\($0))" } ?? "")) }
        if !finderSelection.isEmpty {
            lines.append("Selected files:")
            lines += finderSelection.prefix(30).map { "- \($0)" }
        }
        if let selectedText {
            lines.append("Selected text:")
            lines.append("\"\"\"\n\(selectedText.prefix(6000))\n\"\"\"")
        }
        if let focus, focus != "none" { lines.append("(The request most likely refers to the \(focus.replacingOccurrences(of: "_", with: " ")).)") }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class ContextCapture {
    static let shared = ContextCapture()

    private var contextTask: Task<ScreenContext?, Never>?
    private var menuTask: Task<[String], Never>?
    private var menuCache: [pid_t: (items: [String], at: Date)] = [:]
    private(set) var targetPID: pid_t?
    private(set) var targetApp: String?

    private init() {}

    /// The app the user is working in (the notch panel never activates, so this is the one behind it).
    private var frontmost: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app
    }

    /// Starts capturing context and menu items for the frontmost app.
    /// - Parameter allowCopyFallback: may press ⌘C to read a selection the app doesn't expose
    ///   (only when the user's app still has keyboard focus, i.e. push-to-talk).
    func begin(allowCopyFallback: Bool) {
        guard let app = frontmost else {
            targetPID = nil
            contextTask = nil
            menuTask = nil
            return
        }
        let pid = app.processIdentifier
        targetPID = pid
        targetApp = app.localizedName
        contextTask = Task.detached(priority: .userInitiated) {
            guard let data = await XPCHelperClient.shared.captureContext(processIdentifier: pid, allowCopyFallback: allowCopyFallback) else { return nil }
            return ScreenContext(data: data)
        }
        if let cached = menuCache[pid], Date().timeIntervalSince(cached.at) < 60 {
            menuTask = Task { cached.items }
        } else {
            menuTask = Task.detached(priority: .userInitiated) {
                await XPCHelperClient.shared.menuItems(processIdentifier: pid)
            }
            Task { [weak self] in
                guard let items = await self?.menuTask?.value, !items.isEmpty else { return }
                self?.menuCache[pid] = (items, Date())
            }
        }
    }

    func context(maxWait: TimeInterval = 0.6) async -> ScreenContext? {
        guard let task = contextTask else { return nil }
        return await Self.withTimeout(maxWait) { await task.value } ?? nil
    }

    func menuItems(maxWait: TimeInterval = 0.4) async -> [String] {
        guard let task = menuTask else { return [] }
        return await Self.withTimeout(maxWait) { await task.value } ?? []
    }

    func pressMenuItem(_ path: String) async -> Bool {
        guard let pid = targetPID else { return false }
        return await XPCHelperClient.shared.pressMenuItem(processIdentifier: pid, path: path)
    }

    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
