import Foundation

struct StatementImportResult {
    enum SourceKind { case pdf, csv }
    enum Confidence: Int, Comparable {
        case none = 0
        case low = 1
        case medium = 2
        case high = 3
        public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let source: SourceKind
    let headers: [String]            // canonical: ["date","description","amount","balance","account"]
    let rows: [[String]]             // rows aligned with headers
    let confidence: Confidence
    let warnings: [String]
}
