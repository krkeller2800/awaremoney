import AppKit
import Foundation

struct FakeStatementPDFRenderResult {
    let recipesDirectory: URL
    let outputDirectory: URL
    let renderedPDFs: [RenderedPDF]
}

struct RenderedPDF {
    let recipeFileName: String
    let pdfFileName: String
    let pageCount: Int
    let transactionCount: Int
}

enum FakeStatementPDFRendererError: LocalizedError {
    case noRecipeFiles(URL)
    case invalidRecipeFileName(String)
    case pdfContextCreationFailed(String)
    case pdfWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecipeFiles(let directory):
            return "No recipe JSON files were found in \(directory.path)."
        case .invalidRecipeFileName(let fileName):
            return "Recipe file name is not usable for PDF output: \(fileName)"
        case .pdfContextCreationFailed(let fileName):
            return "Could not create a PDF drawing context for \(fileName)."
        case .pdfWriteFailed(let fileName):
            return "Could not write rendered PDF data for \(fileName)."
        }
    }
}

struct FakeStatementPDFRenderer {
    private let fileManager = FileManager.default
    private let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    private let margin: CGFloat = 54
    private let rowHeight: CGFloat = 18

    func renderRecipes(from recipesDirectory: URL, to outputDirectory: URL) throws -> FakeStatementPDFRenderResult {
        let recipeURLs = try recipeFileURLs(in: recipesDirectory)
        guard !recipeURLs.isEmpty else {
            throw FakeStatementPDFRendererError.noRecipeFiles(recipesDirectory)
        }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        var renderedPDFs: [RenderedPDF] = []

        for recipeURL in recipeURLs {
            let data = try Data(contentsOf: recipeURL)
            let recipe = try decoder.decode(SampleStatementRecipe.self, from: data)
            let baseName = recipeURL.deletingPathExtension().lastPathComponent
            guard !baseName.isEmpty && baseName != "." else {
                throw FakeStatementPDFRendererError.invalidRecipeFileName(recipeURL.lastPathComponent)
            }

            let pdfFileName = "\(baseName).pdf"
            let outputURL = outputDirectory.appendingPathComponent(pdfFileName, isDirectory: false)
            let pageCount = try render(recipe: recipe, to: outputURL, fileName: pdfFileName)

            renderedPDFs.append(RenderedPDF(
                recipeFileName: recipeURL.lastPathComponent,
                pdfFileName: pdfFileName,
                pageCount: pageCount,
                transactionCount: recipe.transactions.count
            ))
        }

        return FakeStatementPDFRenderResult(
            recipesDirectory: recipesDirectory,
            outputDirectory: outputDirectory,
            renderedPDFs: renderedPDFs
        )
    }

    private func recipeFileURLs(in directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            url.pathExtension == "json" && url.lastPathComponent != "privacy-validation-report.json"
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func render(recipe: SampleStatementRecipe, to outputURL: URL, fileName: String) throws -> Int {
        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData) else {
            throw FakeStatementPDFRendererError.pdfContextCreationFailed(fileName)
        }

        var mediaBox = pageRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FakeStatementPDFRendererError.pdfContextCreationFailed(fileName)
        }

        let pages = transactionPages(for: recipe)
        for (pageIndex, transactions) in pages.enumerated() {
            context.beginPDFPage(nil)
            drawPage(recipe: recipe, transactions: transactions, pageIndex: pageIndex, pageCount: pages.count, in: context)
            context.endPDFPage()
        }

        context.closePDF()

        guard pdfData.write(to: outputURL, atomically: true) else {
            throw FakeStatementPDFRendererError.pdfWriteFailed(fileName)
        }

        return pages.count
    }

    private func transactionPages(for recipe: SampleStatementRecipe) -> [[SampleStatementTransaction]] {
        let transactions = recipe.transactions
        let firstPageCapacity = transactionCapacity(tableTop: firstPageTableTop(for: recipe))
        let continuationCapacity = transactionCapacity(tableTop: 172)

        guard transactions.count > firstPageCapacity else {
            return [transactions]
        }

        var pages = [Array(transactions.prefix(firstPageCapacity))]
        var remaining = Array(transactions.dropFirst(firstPageCapacity))

        while !remaining.isEmpty {
            pages.append(Array(remaining.prefix(continuationCapacity)))
            remaining = Array(remaining.dropFirst(continuationCapacity))
        }

        return pages
    }

    private func transactionCapacity(tableTop: CGFloat) -> Int {
        let headerY = pageRect.height - tableTop - 30
        let firstRowY = headerY - 24
        let bottomTextY: CGFloat = 76
        let availableHeight = max(0, firstRowY - bottomTextY)
        return max(1, Int(floor(availableHeight / rowHeight)) + 1)
    }

    private func firstPageTableTop(for recipe: SampleStatementRecipe) -> CGFloat {
        let summaryRowCount = CGFloat(summaryRows(for: recipe).count)
        let firstSummaryRowY = pageRect.height - 298
        let lastSummaryRowY = firstSummaryRowY - ((summaryRowCount - 1) * rowHeight)
        let transactionTitleY = lastSummaryRowY - 34
        return pageRect.height - transactionTitleY
    }

    private func drawPage(
        recipe: SampleStatementRecipe,
        transactions: [SampleStatementTransaction],
        pageIndex: Int,
        pageCount: Int,
        in context: CGContext
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

        drawHeader(recipe: recipe, pageIndex: pageIndex, pageCount: pageCount)

        let tableTop: CGFloat
        if pageIndex == 0 {
            drawCustomerAndAccountBlocks(recipe: recipe)
            drawSummary(recipe: recipe)
            tableTop = firstPageTableTop(for: recipe)
        } else {
            drawText("Transaction Activity Continued", in: CGRect(x: margin, y: pageRect.height - 138, width: 320, height: 24), attributes: .sectionTitle())
            tableTop = 172
        }

        drawTransactionTable(transactions, tableTop: tableTop)
        drawFooter(pageIndex: pageIndex, pageCount: pageCount)

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHeader(recipe: SampleStatementRecipe, pageIndex: Int, pageCount: Int) {
        drawText(recipe.issuerName, in: CGRect(x: margin, y: pageRect.height - 88, width: 280, height: 32), attributes: .title())

        let domainLabel = recipe.issuerName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "&", with: "-and-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let domainURL = "www.\(domainLabel).com"
        drawText(domainURL, in: CGRect(x: margin, y: pageRect.height - 108, width: 280, height: 18), attributes: .body())

        drawText("Statement", in: CGRect(x: pageRect.width - margin - 170, y: pageRect.height - 88, width: 170, height: 32), attributes: .rightTitle())
        drawText("Page \(pageIndex + 1) of \(pageCount)", in: CGRect(x: pageRect.width - margin - 170, y: pageRect.height - 108, width: 170, height: 18), attributes: .rightSmall())
        strokeLine(y: pageRect.height - 124)
    }

    private func drawCustomerAndAccountBlocks(recipe: SampleStatementRecipe) {
        var addressLines = [recipe.customerName]
        addressLines.append(contentsOf: recipe.customerAddress)
        drawText(addressLines.joined(separator: "\n"), in: CGRect(x: margin, y: pageRect.height - 214, width: 250, height: 76), attributes: .body())

        let accountText = [
            "Account: \(recipe.accountName)",
            "Account Number: ****\(recipe.accountLast4)",
            "Statement Period: \(displayDate(recipe.statementStart)) - \(displayDate(recipe.statementEnd))",
            "Statement Type: \(statementTitle(recipe.statementKind))"
        ].joined(separator: "\n")
        drawText(accountText, in: CGRect(x: pageRect.width - margin - 270, y: pageRect.height - 220, width: 270, height: 88), attributes: .rightBody())
    }

    private func drawSummary(recipe: SampleStatementRecipe) {
        drawText("Account Summary", in: CGRect(x: margin, y: pageRect.height - 270, width: 240, height: 22), attributes: .sectionTitle())

        let rows = summaryRows(for: recipe)
        let labelX = margin
        let valueX = pageRect.width - margin - 140
        var y = pageRect.height - 298

        for row in rows {
            drawText(row.label, in: CGRect(x: labelX, y: y, width: 260, height: 18), attributes: .body())
            drawText(row.value, in: CGRect(x: valueX, y: y, width: 140, height: 18), attributes: .rightBody())
            y -= rowHeight
        }
    }

    private func drawTransactionTable(_ transactions: [SampleStatementTransaction], tableTop: CGFloat) {
        drawText("Transaction Activity", in: CGRect(x: margin, y: pageRect.height - tableTop, width: 240, height: 22), attributes: .sectionTitle())

        let headerY = pageRect.height - tableTop - 30
        fillRect(CGRect(x: margin, y: headerY - 3, width: pageRect.width - margin * 2, height: 22), color: NSColor(calibratedWhite: 0.93, alpha: 1))
        drawText("Date", in: CGRect(x: margin + 8, y: headerY, width: 70, height: 16), attributes: .tableHeader())
        drawText("Description", in: CGRect(x: margin + 82, y: headerY, width: 270, height: 16), attributes: .tableHeader())
        drawText("Amount", in: CGRect(x: pageRect.width - margin - 190, y: headerY, width: 80, height: 16), attributes: .rightTableHeader())
        drawText("Balance", in: CGRect(x: pageRect.width - margin - 100, y: headerY, width: 100, height: 16), attributes: .rightTableHeader())

        var y = headerY - 24
        for transaction in transactions {
            drawText(displayDate(transaction.date), in: CGRect(x: margin + 8, y: y, width: 70, height: 16), attributes: .tableBody())
            drawText(transaction.description, in: CGRect(x: margin + 82, y: y, width: 270, height: 16), attributes: .tableBody())
            drawText(currency(transaction.amount), in: CGRect(x: pageRect.width - margin - 190, y: y, width: 80, height: 16), attributes: .rightTableBody())
            drawText(currency(transaction.balance), in: CGRect(x: pageRect.width - margin - 100, y: y, width: 100, height: 16), attributes: .rightTableBody())
            y -= rowHeight
        }
    }

    private func drawFooter(pageIndex: Int, pageCount: Int) {
        strokeLine(y: 54)
        drawText("Generated by FakePDFGen from sanitized fictional recipes. No original statement pages, images, fonts, or metadata are copied.", in: CGRect(x: margin, y: 32, width: pageRect.width - margin * 2, height: 16), attributes: .footer())
        drawText("\(pageIndex + 1)/\(pageCount)", in: CGRect(x: pageRect.width - margin - 50, y: 32, width: 50, height: 16), attributes: .rightFooter())
    }

    private func summaryRows(for recipe: SampleStatementRecipe) -> [(label: String, value: String)] {
        switch recipe.statementKind {
        case .checking:
            let deposits = recipe.transactions.filter { $0.amount > 0 }.map(\.amount).reduce(0, +)
            let withdrawals = recipe.transactions.filter { $0.amount < 0 }.map(\.amount).reduce(0, +)
            return [
                ("Opening Balance", currency(recipe.openingBalance)),
                ("Deposits and Credits", currency(deposits)),
                ("Withdrawals and Debits", currency(abs(withdrawals))),
                ("Ending Balance", currency(recipe.summary.endingBalance))
            ]
        case .creditCard:
            let payments = recipe.transactions.filter { $0.amount < 0 }.map(\.amount).reduce(0, +)
            let purchases = recipe.transactions.filter { $0.amount > 0 }.map(\.amount).reduce(0, +)
            let minimumPayment = recipe.summary.minimumPayment.map(currency) ?? "Not applicable"
            let dueDate = recipe.summary.paymentDueDate.map(displayDate) ?? "Not applicable"
            let apr = recipe.summary.aprPercent.map { String(format: "%.2f%%", $0) } ?? "Not applicable"
            return [
                ("Previous Balance", currency(recipe.openingBalance)),
                ("Payments and Credits", currency(abs(payments))),
                ("Purchases", currency(purchases)),
                ("Interest and Fees", currency(0)),
                ("New Balance", currency(recipe.summary.endingBalance)),
                ("Minimum Payment Due", minimumPayment),
                ("Payment Due Date", dueDate),
                ("APR", apr)
            ]
        case .autoLoan, .mortgage, .genericLoan:
            let payments = recipe.transactions.filter { $0.amount < 0 }.map(\.amount).reduce(0, +)
            let charges = recipe.transactions.filter { $0.amount > 0 }.map(\.amount).reduce(0, +)
            let paymentAmount = recipe.summary.minimumPayment.map(currency) ?? "Not applicable"
            let dueDate = recipe.summary.paymentDueDate.map(displayDate) ?? "Not applicable"
            let apr = recipe.summary.aprPercent.map { String(format: "%.2f%%", $0) } ?? "Not applicable"
            return [
                ("Principal Balance", currency(recipe.summary.endingBalance)),
                ("Opening Balance", currency(recipe.openingBalance)),
                ("Recent Payments", currency(abs(payments))),
                ("Interest and Fees", currency(charges)),
                ("Payment Amount", paymentAmount),
                ("Payment Due Date", dueDate),
                ("Interest Rate", apr)
            ]
        }
    }

    private func statementTitle(_ kind: StatementKind) -> String {
        switch kind {
        case .checking:
            return "Checking"
        case .creditCard:
            return "Credit Card"
        case .autoLoan:
            return "Auto Loan"
        case .mortgage:
            return "Mortgage"
        case .genericLoan:
            return "Loan"
        }
    }

    private func drawText(_ text: String, in rect: CGRect, attributes: [NSAttributedString.Key: Any]) {
        NSString(string: text).draw(in: rect, withAttributes: attributes)
    }

    private func fillRect(_ rect: CGRect, color: NSColor) {
        color.setFill()
        rect.fill()
    }

    private func strokeLine(y: CGFloat) {
        NSColor(calibratedWhite: 0.75, alpha: 1).setStroke()
        NSBezierPath.strokeLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: pageRect.width - margin, y: y))
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
}

private extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    static func title() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: NSColor.black
        ]
    }

    static func rightTitle() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .right, font: NSFont.boldSystemFont(ofSize: 18))
    }

    static func sectionTitle() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .left, font: NSFont.boldSystemFont(ofSize: 13))
    }

    static func body() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .left, font: NSFont.systemFont(ofSize: 10.5))
    }

    static func rightBody() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .right, font: NSFont.systemFont(ofSize: 10.5))
    }

    static func tableHeader() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .left, font: NSFont.boldSystemFont(ofSize: 9.5))
    }

    static func rightTableHeader() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .right, font: NSFont.boldSystemFont(ofSize: 9.5))
    }

    static func tableBody() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .left, font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular))
    }

    static func rightTableBody() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .right, font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular))
    }

    static func footer() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .left, font: NSFont.systemFont(ofSize: 7.5), color: NSColor(calibratedWhite: 0.35, alpha: 1))
    }

    static func rightFooter() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .right, font: NSFont.systemFont(ofSize: 7.5), color: NSColor(calibratedWhite: 0.35, alpha: 1))
    }

    static func rightSmall() -> [NSAttributedString.Key: Any] {
        paragraph(alignment: .right, font: NSFont.systemFont(ofSize: 9))
    }

    private static func paragraph(alignment: NSTextAlignment, font: NSFont, color: NSColor = .black) -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineBreakMode = .byTruncatingTail

        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle
        ]
    }
}
