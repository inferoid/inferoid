import AppKit
import EventKit
import Foundation

struct MeetingCalendarContext {
    let attendeeNames: [String]

    var otherParticipant: String? {
        attendeeNames.count == 1 ? attendeeNames[0] : nil
    }
}

struct MeetingCalendarEvent {
    let title: String
    let startDate: Date
    let endDate: Date
    let attendeeNames: [String]
    let attendeeEmails: [String]
}

/// Calendar is queried locally through EventKit. Google Calendar events already
/// appear here when the user has added that account to macOS Calendar.
enum MeetingCalendar {
    /// True once the user has given Inferoid access to their calendars.
    static var isConnected: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) { return status == .fullAccess }
        return status.rawValue == 3  // .authorized before macOS 14
    }

    /// Asks macOS for calendar access; if it was refused before, opens the Calendars privacy settings instead.
    static func connect() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .denied || status == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            return false
        }
        return await requestAccess(to: EKEventStore())
    }

    static func upcomingEvent(within minutes: Int = 15, now: Date = Date()) async -> MeetingCalendarEvent? {
        let store = EKEventStore()
        guard await requestAccess(to: store) else { return nil }
        let end = now.addingTimeInterval(TimeInterval(max(1, minutes)) * 60)
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.startDate >= now && $0.startDate <= end }
            .sorted { $0.startDate < $1.startDate }
        guard let event = events.first else { return nil }
        let attendees = values(for: event)
        return MeetingCalendarEvent(title: event.title ?? "Calendar event", startDate: event.startDate, endDate: event.endDate,
                                    attendeeNames: attendees.map { $0.name }, attendeeEmails: attendees.compactMap { $0.email })
    }

    static func currentContext(at now: Date = Date()) async -> MeetingCalendarContext {
        let store = EKEventStore()
        guard await requestAccess(to: store) else { return MeetingCalendarContext(attendeeNames: []) }

        let start = now.addingTimeInterval(-15 * 60)
        let end = now.addingTimeInterval(15 * 60)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.startDate <= now && $0.endDate >= now }
            .sorted { $0.endDate.timeIntervalSince($0.startDate) < $1.endDate.timeIntervalSince($1.startDate) }
        guard let event = events.first else { return MeetingCalendarContext(attendeeNames: []) }

        return MeetingCalendarContext(attendeeNames: names(for: event))
    }

    private static func names(for event: EKEvent) -> [String] {
        values(for: event).map { $0.name }
    }

    private static func values(for event: EKEvent) -> [(name: String, email: String?)] {
        var seen = Set<String>()
        // A Google calendar added to macOS is titled with its account address; skip that guest too in case
        // EventKit does not mark them as the current user.
        let own = Set([event.calendar?.title, event.calendar?.source?.title].compactMap { $0?.lowercased() })
        return (event.attendees ?? []).compactMap { participant -> (name: String, email: String?)? in
            guard !participant.isCurrentUser,
                  !own.contains(address(participant.url)),
                  let name = displayName(name: participant.name, url: participant.url),
                  seen.insert(name).inserted else { return nil }
            let email = address(participant.url)
            return (name, email.isEmpty ? nil : email)
        }
    }

    static func address(_ url: URL?) -> String {
        var a = url?.absoluteString.lowercased() ?? ""
        if a.hasPrefix("mailto:") { a = String(a.dropFirst(7)) }
        return a
    }

    /// The guest's name, or one made from their email when the invite only has an address
    /// (Google often sends "ryan.green@antler.co" with no name: that becomes "Ryan Green").
    static func displayName(name: String?, url: URL?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty && !trimmed.contains("@") { return trimmed }
        var address = trimmed.contains("@") ? trimmed : (url?.absoluteString ?? "")
        if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        guard let local = address.split(separator: "@").first, address.contains("@") else { return nil }
        let words = local.split(whereSeparator: { ".-_+".contains($0) }).filter { !$0.allSatisfy(\.isNumber) }
        guard !words.isEmpty else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    private static func requestAccess(to store: EKEventStore) async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
            } else {
                store.requestAccess(to: .event) { granted, _ in continuation.resume(returning: granted) }
            }
        }
    }
}
