//
//  InstantPlanning.swift
//  boringNotch
//
//  Instant reminders, calendar events and timers. Times are parsed in code
//  (RequestParsing); EventKit writes directly to Reminders/Calendar.
//

import AppKit
import EventKit
import Foundation

@MainActor
enum InstantPlanning {
    private static let store = EKEventStore()

    // MARK: Reminders

    static func addReminder(from request: String) async -> String? {
        let parsed = RequestParsing.datedText(request, commandPatterns: RequestParsing.reminderCommands)
        guard !parsed.title.isEmpty else { return nil }
        guard (try? await store.requestFullAccessToReminders()) == true,
              let list = store.defaultCalendarForNewReminders() else {
            return "Allow Reminders access in System Settings"
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = parsed.title
        reminder.calendar = list
        if let date = parsed.date {
            var parts: Set<Calendar.Component> = [.year, .month, .day]
            if parsed.hasTime { parts.formUnion([.hour, .minute]) }
            reminder.dueDateComponents = Calendar.current.dateComponents(parts, from: date)
            if parsed.hasTime { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        }
        do {
            try store.save(reminder, commit: true)
        } catch {
            return nil
        }
        guard let date = parsed.date else { return "Reminder: \(parsed.title)" }
        return "Reminder: \(parsed.title) · \(describe(date, withTime: parsed.hasTime))"
    }

    // MARK: Events

    static func addEvent(from request: String) async -> String? {
        let parsed = RequestParsing.datedText(request, commandPatterns: RequestParsing.eventCommands)
        guard let start = parsed.date, !parsed.title.isEmpty else { return nil }
        guard (try? await store.requestFullAccessToEvents()) == true,
              let calendar = store.defaultCalendarForNewEvents else {
            return "Allow Calendar access in System Settings"
        }
        let event = EKEvent(eventStore: store)
        event.title = parsed.title
        event.calendar = calendar
        event.startDate = start
        if parsed.hasTime {
            event.endDate = start.addingTimeInterval(parsed.duration ?? 3600)
        } else {
            event.isAllDay = true
            event.endDate = start
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return nil
        }
        var when = describe(start, withTime: parsed.hasTime)
        if parsed.hasTime, let end = event.endDate {
            when += "–" + end.formatted(date: .omitted, time: .shortened)
        }
        return "Added \(parsed.title) · \(when)"
    }

    /// "today 6:00 PM", "tomorrow", "Fri 10:00 AM".
    static func describe(_ date: Date, withTime: Bool) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDateInToday(date) { day = "today" }
        else if calendar.isDateInTomorrow(date) { day = "tomorrow" }
        else { day = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
        return withTime ? "\(day) \(date.formatted(date: .omitted, time: .shortened))" : day
    }
}

// MARK: - Timers

@MainActor
final class AgentTimers: ObservableObject {
    static let shared = AgentTimers()

    struct Countdown: Identifiable, Equatable {
        let id = UUID()
        let label: String?
        let end: Date
        let total: TimeInterval
    }

    @Published private(set) var timers: [Countdown] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// The timer that ends soonest (shown in the closed notch).
    var next: Countdown? { timers.min { $0.end < $1.end } }

    func start(_ seconds: TimeInterval, label: String?) -> String {
        let countdown = Countdown(label: label, end: Date().addingTimeInterval(seconds), total: seconds)
        timers.append(countdown)
        tasks[countdown.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.fire(countdown)
        }
        let name = label.map { "\($0) timer" } ?? "Timer"
        return "\(name) · \(Self.format(seconds))"
    }

    /// Cancels the timer ending soonest; returns a label for the result.
    func cancelNext() -> String? {
        guard let countdown = next else { return nil }
        tasks[countdown.id]?.cancel()
        tasks[countdown.id] = nil
        timers.removeAll { $0.id == countdown.id }
        return "Cancelled \(countdown.label.map { "\($0) timer" } ?? "timer")"
    }

    private func fire(_ countdown: Countdown) {
        timers.removeAll { $0.id == countdown.id }
        tasks[countdown.id] = nil
        let sound = NSSound(named: "Glass")
        Task {
            for _ in 0..<3 {
                sound?.stop()
                sound?.play()
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
        AgentManager.shared.flashResult(icon: "timer",
                                        label: "\(countdown.label.map { "\($0) timer" } ?? "Timer") done",
                                        duration: 8)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
