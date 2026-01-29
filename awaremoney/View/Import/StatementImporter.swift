import Foundation

struct StatementImporter {

    func importStatement(from url: URL,
                         prefer mode: PDFStatementExtractor.Mode = .transactions) throws -> StatementImportResult {
        switch detectKind(url) {
        case .csv:
            let (rows, headers) = try CSVStatementExtractor.parse(url: url)
            return gateCSV(rows: rows, headers: headers)

        case .pdf:
            let (rows, headers) = try PDFStatementExtractor.parse(url: url, mode: mode)
            return gatePDF(rows: rows, headers: headers, mode: mode)

        case .unknown:
            throw ImportError.unknownFormat
        }
    }

    // MARK: - Kind detection

    private enum FileKind { case pdf, csv, unknown }

    private func detectKind(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ["csv", "tsv"].contains(ext) { return .csv }
        return .unknown
    }

    // MARK: - Gating & confidence

    private func gatePDF(rows: [[String]], headers: [String], mode: PDFStatementExtractor.Mode) -> StatementImportResult {
        let confidence = confidenceForPDF(rows: rows)
        var warnings: [String] = []
        if confidence <= .low {
            warnings.append("Low confidence parsing PDF. Consider importing a CSV for best results.")
        }
        if mode == .transactions && confidence <= .low {
            warnings.append("You can also try Summary Only mode to avoid mis-parsed transactions.")
        }
        return StatementImportResult(source: .pdf, headers: headers, rows: rows, confidence: confidence, warnings: warnings)
    }

    private func gateCSV(rows: [[String]], headers: [String]) -> StatementImportResult {
        let confidence: StatementImportResult.Confidence = rows.isEmpty ? .none : .high
        var warnings: [String] = []
        if rows.isEmpty {
            warnings.append("No rows detected in CSV. Check delimiter and header mapping.")
        }
        return StatementImportResult(source: .csv, headers: headers, rows: rows, confidence: confidence, warnings: warnings)
    }

    private func confidenceForPDF(rows: [[String]]) -> StatementImportResult.Confidence {
        // Simple heuristic based on count and basic field validity
        let count = rows.count
        if count == 0 { return .none }
        if count < 5 { return .low }
        if count < 20 { return .medium }
        return .high
    }
}
