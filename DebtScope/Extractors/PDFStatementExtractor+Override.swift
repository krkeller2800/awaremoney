import Foundation

extension PDFStatementExtractor {
    // Passthrough overload that accepts an optional user override but currently delegates to the existing API.
    // This provides a single place to honor overrides later without changing call sites again.
    static func parse(url: URL, mode: PDFStatementExtractor.Mode, override: StatementImporter.UserOverride?) throws -> ([[String]], [String]) {
        AMLogging.log("PDFStatementExtractor+Override: parse invoked with mode=\(mode) override=\(String(describing: override))", component: "PDFStatementExtractor")
        return try parse(url: url, mode: mode)
    }
}
