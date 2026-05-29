import Foundation

extension PDFStatementExtractor {
    static func parse(url: URL, mode: PDFStatementExtractor.Mode, override: StatementImporter.UserOverride?) throws -> ([[String]], [String]) {
        let mappedOverride: AccountKind? = {
            switch override {
            case .creditCard:
                return .unknown // Credit cards intentionally use the extractor's unknown bucket, then normalize to creditCard downstream.
            case .loan:
                return .loan
            case .bank:
                return nil
            case .brokerage:
                return .investment
            case .none:
                return nil
            }
        }()

        AMLogging.log(
            "PDFStatementExtractor+Override: parse invoked with mode=\(mode) override=\(String(describing: override)) mappedOverride=\(String(describing: mappedOverride))",
            component: "PDFStatementExtractor"
        )
        return try parse(url: url, mode: mode, userOverride: mappedOverride)
    }
}
