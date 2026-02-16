// PaymentFrequency+Helpers.swift
// Canonical mapping, factors, and labels for PaymentFrequency

import Foundation

extension PaymentFrequency {
    /// Maps synonymous cases to a canonical representation while preserving distinct periods.
    /// - biWeekly -> biweekly
    /// - twiceMonthly -> semimonthly
    /// - annual -> yearly
    /// Other cases are returned as-is.
    var normalized: PaymentFrequency {
        switch self {
        case .biWeekly:
            return .biweekly
        case .twiceMonthly:
            return .semimonthly
        case .annual:
            return .yearly
        default:
            return self
        }
    }

    /// Monthly equivalent multiplier for a given frequency.
    /// For example, biweekly -> 26/12, semimonthly -> 2, yearly -> 1/12, one-time -> 0.
    var monthlyEquivalentFactor: Decimal {
        switch normalized {
        case .monthly:
            return 1
        case .semimonthly:
            return 2
        case .biweekly:
            return Decimal(26) / Decimal(12)
        case .weekly:
            return Decimal(52) / Decimal(12)
        case .yearly:
            return Decimal(1) / Decimal(12)
        case .quarterly:
            return Decimal(1) / Decimal(3)
        case .semiAnnual:
            return Decimal(1) / Decimal(6)
        case .oneTime:
            return 0
        case .biWeekly:
            // Should be normalized already, but keep for safety
            return Decimal(26) / Decimal(12)
        case .twiceMonthly:
            return 2
        case .annual:
            return Decimal(1) / Decimal(12)
        case .socialSecurity:
            return 1
        }
    }

    /// Human-readable label for the frequency.
    var displayLabel: String {
        switch normalized {
        case .monthly: return "Monthly"
        case .semimonthly: return "Twice per month"
        case .biweekly: return "Every 2 weeks"
        case .weekly: return "Weekly"
        case .yearly: return "Yearly"
        case .quarterly: return "Quarterly"
        case .semiAnnual: return "Semiannual"
        case .oneTime: return "One-time"
        case .biWeekly: return "Every 2 weeks"
        case .twiceMonthly: return "Twice per month"
        case .annual: return "Yearly"
        case .socialSecurity: return "Social Security"
        }
    }
}
