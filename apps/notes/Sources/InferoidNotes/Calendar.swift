import EventKit
import Foundation

struct MeetingCalendarContext {
    let attendeeNames: [String]

    var otherParticipant: String? {
        attendeeNames.count == 1 ? attendeeNames[0] : nil
    }
}

/// Calendar is queried locally through EventKit. Google Calendar events already
/// appear here when the user has added that account to macOS Calendar.
enum MeetingCalendar {
    static func currentContext(at now: Date = Date()) async -> MeetingCalendarContext {
        let store = EKEventStore()
        guard await requestAccess(to: store) else { return MeetingCalendarContext(attendeeNames: []) }

        let start = now.addingTimeInterval(-15 * 60)
        let end = now.addingTimeInterval(15 * 60)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.startDate <= now && $0.endDate >= now }
            .sorted { $0.endDate.timeIntervalSince($0.startDate) < $1.endDate.timeIntervalSince($1.startDate) }
        guard let event = events.first else { return MeetingCalendarContext(attendeeNames: []) }

        var seen = Set<String>()
        let names = (event.attendees ?? []).compactMap { participant -> String? in
            guard !participant.isCurrentUser,
                  let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  seen.insert(name).inserted else { return nil }
            return name
        }
        return MeetingCalendarContext(attendeeNames: names)
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
