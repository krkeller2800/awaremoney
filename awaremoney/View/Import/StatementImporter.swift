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
            var augmentedRows = rows

            if let fullText = PDFTextExtractor.extractText(from: url) {
                AMLogging.log("StatementImporter: PDF raw text length=\(fullText.count)", component: "StatementImporter")

                if let interestSection = PDFTextExtractor.extractInterestChargesSection(from: fullText) {
                    AMLogging.log("StatementImporter: Interest Charges section found — length=\(interestSection.count)", component: "StatementImporter")
                    augmentedRows.append([interestSection])
                } else {
                    AMLogging.log("StatementImporter: Interest Charges section not found in raw text", component: "StatementImporter")
                }

                if let balanceSection = PDFTextExtractor.extractBalanceSummarySection(from: fullText) {
                    AMLogging.log("StatementImporter: Balance Summary section found — length=\(balanceSection.count)", component: "StatementImporter")
                    augmentedRows.append([balanceSection])
                } else {
                    AMLogging.log("StatementImporter: Balance Summary section not found — appending full text fallback", component: "StatementImporter")
                    augmentedRows.append([fullText])
                }
            } else {
                AMLogging.log("StatementImporter: PDF raw text unavailable — proceeding without synthetic sections", component: "StatementImporter")
            }

            return gatePDF(rows: augmentedRows, headers: headers, mode: mode)

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
            warnings.append("If your institution fails to parse, fill in the data manually")
        }
        if mode == .transactions && confidence <= .low {
            warnings.append("For a monthly snapshot, try Summary Only mode; for mid-month detail, import a CSV.")
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

