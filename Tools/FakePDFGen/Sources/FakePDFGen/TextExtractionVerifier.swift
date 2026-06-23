import Foundation
import PDFKit

struct TextExtractionVerificationResult {
    let outputDirectory: URL
    let recipesDirectory: URL?
    let verifiedPDFs: [VerifiedPDF]
    let findings: [TextExtractionFinding]

    var hasFailures: Bool {
        !findings.isEmpty
    }
}

struct VerifiedPDF {
    let pdfFileName: String
    let recipeFileName: String?
    let pageCount: Int
    let extractedCharacterCount: Int
    let expectedTransactionCount: Int?
}

struct TextExtractionFinding {
    let pdfFileName: String
    let message: String
}

enum TextExtractionVerifierError: LocalizedError {
    case noPDFs(URL)

    var errorDescription: String? {
        switch self {
        case .noPDFs(let directory):
            return "No PDF files were found in \(directory.path)."
        }
    }
}

struct TextExtractionVerifier {
    private let fileManager = FileManager.default

    func verify(outputDirectory: URL, recipesDirectory: URL?) throws -> TextExtractionVerificationResult {
        let pdfURLs = try pdfFileURLs(in: outputDirectory)
        guard !pdfURLs.isEmpty else {
            throw TextExtractionVerifierError.noPDFs(outputDirectory)
        }

        let recipesByBaseName = try recipesDirectory.map(loadRecipesByBaseName) ?? [:]
        var verifiedPDFs: [VerifiedPDF] = []
        var findings: [TextExtractionFinding] = []

        for pdfURL in pdfURLs {
            let pdfFileName = pdfURL.lastPathComponent
            guard let document = PDFDocument(url: pdfURL) else {
                findings.append(TextExtractionFinding(pdfFileName: pdfFileName, message: "PDFKit could not open the file."))
                continue
            }

            let extractedText = extractText(from: document)
            let baseName = pdfURL.deletingPathExtension().lastPathComponent
            let recipe = recipesByBaseName[baseName]

            findings.append(contentsOf: textFindings(
                pdfFileName: pdfFileName,
                document: document,
                extractedText: extractedText
            ))

            if let recipesDirectory, recipe == nil {
                findings.append(TextExtractionFinding(
                    pdfFileName: pdfFileName,
                    message: "No matching recipe JSON was found in \(recipesDirectory.path)."
                ))
            }

            if let recipe {
                findings.append(contentsOf: recipeFindings(
                    pdfFileName: pdfFileName,
                    recipe: recipe,
                    extractedText: extractedText
                ))
                findings.append(contentsOf: recipeIntegrityFindings(
                    pdfFileName: pdfFileName,
                    recipe: recipe
                ))
            }

            verifiedPDFs.append(VerifiedPDF(
                pdfFileName: pdfFileName,
                recipeFileName: recipe.map { _ in "\(baseName).json" },
                pageCount: document.pageCount,
                extractedCharacterCount: extractedText.count,
                expectedTransactionCount: recipe?.transactions.count
            ))
        }

        return TextExtractionVerificationResult(
            outputDirectory: outputDirectory,
            recipesDirectory: recipesDirectory,
            verifiedPDFs: verifiedPDFs,
            findings: findings
        )
    }

    private func pdfFileURLs(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "pdf" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func loadRecipesByBaseName(from directory: URL) throws -> [String: SampleStatementRecipe] {
        let recipeURLs = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" && $0.lastPathComponent != "privacy-validation-report.json" }

        let decoder = JSONDecoder()
        var recipesByBaseName: [String: SampleStatementRecipe] = [:]

        for recipeURL in recipeURLs {
            let data = try Data(contentsOf: recipeURL)
            let recipe = try decoder.decode(SampleStatementRecipe.self, from: data)
            recipesByBaseName[recipeURL.deletingPathExtension().lastPathComponent] = recipe
        }

        return recipesByBaseName
    }

    private func extractText(from document: PDFDocument) -> String {
        var pages: [String] = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let pageText = page.string else {
                continue
            }

            pages.append(pageText)
        }

        return pages
            .joined(separator: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func textFindings(
        pdfFileName: String,
        document: PDFDocument,
        extractedText: String
    ) -> [TextExtractionFinding] {
        var findings: [TextExtractionFinding] = []

        if document.pageCount <= 0 {
            findings.append(TextExtractionFinding(pdfFileName: pdfFileName, message: "PDF has no pages."))
        }

        if extractedText.isEmpty {
            findings.append(TextExtractionFinding(pdfFileName: pdfFileName, message: "PDFKit extracted no selectable text."))
            return findings
        }

        let requiredText = [
            "Statement",
            "Account Summary",
            "Transaction Activity",
            "Date",
            "Description",
            "Amount",
            "Balance"
        ]

        for text in requiredText where !extractedText.localizedCaseInsensitiveContains(text) {
            findings.append(TextExtractionFinding(pdfFileName: pdfFileName, message: "Missing expected text: \(text)."))
        }

        return findings
    }

    private func recipeIntegrityFindings(
        pdfFileName: String,
        recipe: SampleStatementRecipe
    ) -> [TextExtractionFinding] {
        var findings: [TextExtractionFinding] = []

        var runningBalance = rounded(recipe.openingBalance)
        for transaction in recipe.transactions {
            runningBalance = rounded(runningBalance + transaction.amount)
            if rounded(transaction.balance) != runningBalance {
                findings.append(TextExtractionFinding(
                    pdfFileName: pdfFileName,
                    message: "Transaction balance does not reconcile for \(transaction.date) \(transaction.description)."
                ))
            }
        }

        if rounded(recipe.summary.endingBalance) != runningBalance {
            findings.append(TextExtractionFinding(
                pdfFileName: pdfFileName,
                message: "Summary ending balance does not equal opening balance plus transactions."
            ))
        }

        var identityCounts: [String: Int] = [:]
        var dateDescriptionCounts: [String: Int] = [:]
        for transaction in recipe.transactions {
            let key = "\(transaction.date)|\(Int((transaction.amount * 100.0).rounded()))|\(transaction.description.lowercased())"
            identityCounts[key, default: 0] += 1

            let dateDescriptionKey = "\(transaction.date)|\(transaction.description.lowercased())"
            dateDescriptionCounts[dateDescriptionKey, default: 0] += 1
        }

        for (_, count) in identityCounts where count > 1 {
            findings.append(TextExtractionFinding(
                pdfFileName: pdfFileName,
                message: "Recipe contains duplicate transaction import identities."
            ))
            break
        }

        for (_, count) in dateDescriptionCounts where count > 1 {
            findings.append(TextExtractionFinding(
                pdfFileName: pdfFileName,
                message: "Recipe contains duplicate same-date transaction descriptions."
            ))
            break
        }

        return findings
    }

    private func recipeFindings(
        pdfFileName: String,
        recipe: SampleStatementRecipe,
        extractedText: String
    ) -> [TextExtractionFinding] {
        var findings: [TextExtractionFinding] = []
        let expectedStrings = recipeExpectedStrings(for: recipe)

        for expected in expectedStrings where !extractedText.localizedCaseInsensitiveContains(expected) {
            findings.append(TextExtractionFinding(pdfFileName: pdfFileName, message: "Missing recipe-backed text: \(expected)."))
        }

        for transaction in recipe.transactions {
            let expectedTransactionStrings = [
                displayDate(transaction.date),
                transaction.description,
                currency(transaction.amount),
                currency(transaction.balance)
            ]

            for expected in expectedTransactionStrings where !extractedText.localizedCaseInsensitiveContains(expected) {
                findings.append(TextExtractionFinding(
                    pdfFileName: pdfFileName,
                    message: "Missing transaction text for \(transaction.date): \(expected)."
                ))
            }
        }

        return findings
    }

    private func recipeExpectedStrings(for recipe: SampleStatementRecipe) -> [String] {
        var expected = [
            recipe.issuerName,
            recipe.customerName,
            recipe.accountName,
            "****\(recipe.accountLast4)",
            displayDate(recipe.statementStart),
            displayDate(recipe.statementEnd),
            currency(recipe.openingBalance),
            currency(recipe.summary.endingBalance)
        ]

        if let minimumPayment = recipe.summary.minimumPayment {
            expected.append(currency(minimumPayment))
        }

        if let paymentDueDate = recipe.summary.paymentDueDate {
            expected.append(displayDate(paymentDueDate))
        }

        if let aprPercent = recipe.summary.aprPercent {
            expected.append(String(format: "%.2f%%", aprPercent))
        }

        return expected
    }

    private func displayDate(_ rawValue: String) -> String {
        let parts = rawValue.split(separator: "-")
        guard parts.count == 3 else {
            return rawValue
        }

        return "\(parts[1])/\(parts[2])/\(parts[0])"
    }

    private func currency(_ value: Double) -> String {
        let formatted = String(format: "$%.2f", abs(value))
        return value < 0 ? "(\(formatted))" : formatted
    }

    private func rounded(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }
}
