import Foundation
import AfterSixCore

struct Fixture: Decodable {
    let schema: Int
    let timeZone: String
    let cases: [Case]
}

struct Case: Decodable {
    let id: String
    let at: String
    let mode: WorkdayMode
    let workMinutes: Int
    let breakMinutes: Int
    let expected: Expected
}

struct Expected: Decodable {
    let departureMinutes: Int
    let arrivalAllowed: Bool
}

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(message) }
}

do {
    try require(CommandLine.arguments.count == 2, "Pass the shared attendance JSON path")
    let file = URL(fileURLWithPath: CommandLine.arguments[1])
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    try require(fixture.schema == 1, "Unsupported fixture schema")
    try require(!fixture.cases.isEmpty, "Fixture must contain cases")
    guard let zone = TimeZone(identifier: fixture.timeZone) else {
        throw CheckFailure("Invalid fixture time zone")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let format = ISO8601DateFormatter()
    var ids = Set<String>()
    for sample in fixture.cases {
        try require(!sample.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    ids.insert(sample.id).inserted, "Empty or duplicate case id: \(sample.id)")
        guard let at = format.date(from: sample.at) else {
            throw CheckFailure("\(sample.id): invalid ISO arrival")
        }
        var settings = WorkSettings()
        settings.workMinutes = sample.workMinutes
        settings.breakMinutes = sample.breakMinutes
        try require(settings.isValid, "\(sample.id): invalid work settings")
        let arrival = Arrival(day: Attendance.dayKey(at, calendar: calendar), time: at,
                              source: .manual, timeZoneID: zone.identifier, mode: sample.mode)
        let minutes = Attendance.departure(for: arrival, settings: settings).timeIntervalSince(at) / 60
        let allowed = Attendance.isAllowed(at, for: sample.mode, calendar: calendar)
        try require(minutes == Double(sample.expected.departureMinutes),
                    "\(sample.id): departure minutes expected \(sample.expected.departureMinutes), got \(minutes)")
        try require(allowed == sample.expected.arrivalAllowed,
                    "\(sample.id): arrival eligibility expected \(sample.expected.arrivalAllowed), got \(allowed)")
    }
    print("PASS Swift shared attendance: \(ids.count) cases")
} catch {
    FileHandle.standardError.write(Data("FAIL Swift shared attendance: \(error)\n".utf8))
    exit(1)
}
