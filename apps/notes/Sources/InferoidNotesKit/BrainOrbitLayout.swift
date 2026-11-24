import Foundation

/// Shared orbit math. It deliberately knows nothing about SwiftUI so a future 3D renderer can reuse it.
public struct BrainOrbitPoint: Hashable, Sendable {
    public let personID: Int64
    public let level: Int
    public let position: CGPoint

    public init(personID: Int64, level: Int, position: CGPoint) {
        self.personID = personID; self.level = level; self.position = position
    }
}

public enum BrainCloseness {
    public static func suggestedLevel(meetingCount: Int, lastMet: Date?, now: Date = Date()) -> Int {
        guard let lastMet else { return 5 }
        let days = max(0, now.timeIntervalSince(lastMet) / 86_400)
        if days <= 14 && meetingCount >= 4 { return 1 }
        if days <= 30 && meetingCount >= 2 { return 2 }
        if days <= 60 { return 3 }
        if days <= 120 { return 4 }
        return 5
    }
}

public enum BrainOrbitLayout {
    public static let ringCount = 5

    /// Space a ring needs from the one inside it: room for an avatar and its name when the ring has people,
    /// a thin gap when it is empty. Rings with many people also grow so neighbours on the ring never touch.
    static let youRadius: CGFloat = 104
    static let occupiedGap: CGFloat = 66
    static let emptyGap: CGFloat = 28
    static let personArc: CGFloat = 104

    static func level(of person: BrainOrbitPerson) -> Int { max(1, min(ringCount, person.closenessLevel ?? person.suggestedClosenessLevel)) }

    /// Ring radii grow with the people on them: adding someone to a ring pushes the rings outside it out.
    /// At the default zoom the layout shrinks a little to fit small windows, never so much that people overlap.
    public static func radii(people: [BrainOrbitPerson] = [], size: CGSize, zoom: CGFloat = 1) -> [CGFloat] {
        var counts = Array(repeating: 0, count: ringCount)
        for person in people { counts[level(of: person) - 1] += 1 }
        var radii: [CGFloat] = []
        var previous: CGFloat = 0
        for index in 0..<ringCount {
            let occupied = counts[index] > 0
            var radius = index == 0 ? (occupied ? youRadius : youRadius - 30) : previous + (occupied || counts[index - 1] > 0 ? occupiedGap : emptyGap)
            if occupied { radius = max(radius, CGFloat(counts[index]) * personArc / (2 * .pi)) }
            radii.append(radius)
            previous = radius
        }
        let usable = max(120, min(size.width, size.height) / 2 - 46)
        let fit = min(1, max(0.82, usable / (radii.last ?? usable)))
        return radii.map { $0 * fit * zoom }
    }

    public static func points(people: [BrainOrbitPerson], size: CGSize, zoom: CGFloat = 1,
                              offset: CGSize = .zero) -> [BrainOrbitPoint] {
        guard !people.isEmpty else { return [] }
        let center = CGPoint(x: size.width / 2 + offset.width, y: size.height / 2 + offset.height)
        let radii = Self.radii(people: people, size: size, zoom: zoom)
        var placed: [BrainOrbitPoint] = []
        let grouped = Dictionary(grouping: people) { level(of: $0) }
        for level in 1...ringCount {
            let members = (grouped[level] ?? []).sorted { $0.entity.name.localizedCaseInsensitiveCompare($1.entity.name) == .orderedAscending }
            guard !members.isEmpty else { continue }
            let radius = radii[level - 1]
            // Each ring starts at a different angle so people on neighbouring rings never stack in one column,
            // and nobody sits straight above You (where it would look like a list).
            let start = -Double.pi / 2 + 0.7 + Double(level) * 2.4
            let spread = (2 * Double.pi) / Double(max(members.count, 1))
            for (index, person) in members.enumerated() {
                let angle = start + spread * Double(index)
                let point = CGPoint(x: center.x + CGFloat(cos(angle)) * radius, y: center.y + CGFloat(sin(angle)) * radius)
                placed.append(BrainOrbitPoint(personID: person.entity.id, level: level, position: point))
            }
        }
        return placed
    }

}
