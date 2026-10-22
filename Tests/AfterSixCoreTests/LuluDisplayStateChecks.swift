import Foundation
import AfterSixCore

func checkLuluDisplayState() {
    let departure = Date(timeIntervalSince1970: 10_000)
    let before = departure.addingTimeInterval(-0.001)
    // A missing arrival wins over an expired time, regardless of the selected work type.
    for type in ManualDayType.allCases {
        let expected: LuluDisplayState = type == .annualLeave ? .annualLeave : .waiting
        expectEqual(LuluDisplayState.resolve(dayType: type, isSkipped: false,
                    hasArrival: false, departure: departure, now: departure), expected)
    }
    for type in ManualDayType.allCases {
        let expected: LuluDisplayState = type == .annualLeave ? .annualLeave : .dayOff
        expectEqual(LuluDisplayState.resolve(dayType: type, isSkipped: true,
                    hasArrival: true, departure: departure, now: departure), expected)
    }
    let working: [(ManualDayType, LuluDisplayState)] = [(.regular, .regular), (.luluDay, .luluDay),
        (.morningHalf, .morningHalf), (.afternoonHalf, .afternoonHalf)]
    for (type, expected) in working {
        expectEqual(LuluDisplayState.resolve(dayType: type, isSkipped: false,
                    hasArrival: true, departure: departure, now: before), expected)
        for now in [departure, departure.addingTimeInterval(0.001)] {
            expectEqual(LuluDisplayState.resolve(dayType: type, isSkipped: false,
                        hasArrival: true, departure: departure, now: now), .readyToLeave)
        }
        expectEqual(LuluDisplayState.resolve(dayType: type, isSkipped: false,
                    hasArrival: true, departure: nil, now: departure), expected)
    }
    expectEqual(LuluDisplayState.resolve(dayType: .annualLeave, isSkipped: false,
                hasArrival: true, departure: departure, now: departure), .annualLeave)
    expectEqual(LuluDisplayState.allCases.count, 8)
    print("PASS owl display: eight states, leave/day-off/no-arrival priority, exact departure boundary; no attendance mutation")
}
