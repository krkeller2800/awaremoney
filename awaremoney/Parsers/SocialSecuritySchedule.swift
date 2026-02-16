import Foundation

/// Represents the Social Security Wednesday group assigned based on the beneficiary's birthday day-of-month.
/// Social Security payments are scheduled on the 2nd, 3rd, or 4th Wednesday of each month depending on this group.
public enum SocialSecurityWednesdayGroup: Int {
    /// Birthday days 1...10 correspond to the 2nd Wednesday.
    case secondWednesday = 2
    /// Birthday days 11...20 correspond to the 3rd Wednesday.
    case thirdWednesday = 3
    /// Birthday days 21...31 correspond to the 4th Wednesday.
    case fourthWednesday = 4

    /// Computes the SocialSecurityWednesdayGroup based on the day of the month of the beneficiary's birthday.
    ///
    /// - Parameter birthdayDay: The day of the month (1...31) of the beneficiary's birthday.
    /// - Returns: The corresponding SocialSecurityWednesdayGroup.
    public static func group(forBirthdayDay birthdayDay: Int) -> SocialSecurityWednesdayGroup {
        switch birthdayDay {
        case 1...10: return .secondWednesday
        case 11...20: return .thirdWednesday
        default: return .fourthWednesday
        }
    }
}

/// Utilities to compute Social Security payment dates based on beneficiary birthday day-of-month.
/// Social Security payments are scheduled on the 2nd, 3rd, or 4th Wednesday of each month depending on the birthday.
public struct SocialSecuritySchedule {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Returns the date of the nth occurrence of a specific weekday in a given month and year.
    ///
    /// - Parameters:
    ///   - weekday: The weekday to find (1=Sunday, 2=Monday, ..., 7=Saturday).
    ///   - nth: The occurrence number (e.g., 2 for second).
    ///   - month: The month (1...12).
    ///   - year: The year.
    /// - Returns: The Date of the nth weekday in the month, or nil if it does not exist.
    public static func nthWeekday(_ weekday: Int, nth: Int, month: Int, year: Int) -> Date? {
        guard (1...7).contains(weekday), nth > 0, (1...12).contains(month) else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.weekday = weekday
        components.weekdayOrdinal = nth

        return calendar.date(from: components)
    }

    /// Computes the scheduled Social Security payment date for a given birthday day-of-month and a target year/month.
    ///
    /// - Parameters:
    ///   - birthdayDay: The beneficiary's birthday day of month (1...31).
    ///   - month: The target payment month (1...12).
    ///   - year: The target payment year.
    /// - Returns: The scheduled payment Date on the appropriate Wednesday.
    public static func scheduledPaymentDate(birthdayDay: Int, month: Int, year: Int) -> Date? {
        let group = SocialSecurityWednesdayGroup.group(forBirthdayDay: birthdayDay)
        // Wednesday in Calendar is 4 (Sunday=1, Monday=2, Tuesday=3, Wednesday=4)
        return nthWeekday(4, nth: group.rawValue, month: month, year: year)
    }

    /// Computes the next Social Security payment date after a given date for a beneficiary's birthday day-of-month.
    ///
    /// - Parameters:
    ///   - afterDate: The date after which the next payment date is sought.
    ///   - birthdayDay: The beneficiary's birthday day of month (1...31).
    /// - Returns: The next scheduled payment Date strictly after `afterDate`.
    public static func nextPaymentDate(after afterDate: Date, birthdayDay: Int) -> Date? {
        let calendar = self.calendar
        var components = calendar.dateComponents([.year, .month], from: afterDate)

        // Check current month first
        if let currentMonthPayment = scheduledPaymentDate(birthdayDay: birthdayDay, month: components.month!, year: components.year!),
           currentMonthPayment > afterDate {
            return currentMonthPayment
        }

        // Otherwise check next months until a date > afterDate is found
        for monthOffset in 1...12 {
            if let nextMonthDate = calendar.date(byAdding: .month, value: monthOffset, to: afterDate) {
                let nextComponents = calendar.dateComponents([.year, .month], from: nextMonthDate)
                if let paymentDate = scheduledPaymentDate(birthdayDay: birthdayDay, month: nextComponents.month!, year: nextComponents.year!),
                   paymentDate > afterDate {
                    return paymentDate
                }
            }
        }

        return nil
    }

    /// Generates upcoming Social Security payment dates starting after a given date for a beneficiary's birthday day-of-month.
    ///
    /// - Parameters:
    ///   - afterDate: The date after which to start generating payment dates.
    ///   - birthdayDay: The beneficiary's birthday day of month (1...31).
    ///   - count: The number of upcoming payment dates to generate.
    /// - Returns: An array of Dates representing upcoming scheduled payment dates.
    public static func upcomingPayments(after afterDate: Date, birthdayDay: Int, count: Int) -> [Date] {
        var payments: [Date] = []
        var currentAfterDate = afterDate

        while payments.count < count {
            guard let nextDate = nextPaymentDate(after: currentAfterDate, birthdayDay: birthdayDay) else {
                break
            }
            payments.append(nextDate)
            currentAfterDate = nextDate
        }

        return payments
    }
}
