import AppKit
import Foundation
import PDFKit

struct FakePDFGenCLI {
    let executableName: String

    func run(arguments: [String]) -> Int32 {
        let commandArguments = Array(arguments.dropFirst())

        if commandArguments.isEmpty || commandArguments.contains("--help") || commandArguments.contains("-h") {
            printHelp()
            return 0
        }

        let command = commandArguments.first ?? ""
        let supportedCommands = Set(["inspect", "build-recipes", "render", "verify"])

        if command == "inspect" {
            return inspect(arguments: Array(commandArguments.dropFirst()))
        }

        if command == "build-recipes" {
            return buildRecipes(arguments: Array(commandArguments.dropFirst()))
        }

        if supportedCommands.contains(command) {
            print("'\(command)' is planned for a later implementation step.")
            print("")
            printHelp()
            return 2
        }

        print("Unsupported argument: \(command)")
        print("")
        printHelp()
        return 2
    }

    private func inspect(arguments: [String]) -> Int32 {
        do {
            let options = try CLIOptions(arguments: arguments)
            guard let inputPath = options.value(for: "--input") else {
                throw CLIError.missingRequiredOption("--input")
            }

            let inputURL = URL(fileURLWithPath: inputPath).standardizedFileURL
            let summary = try BackupPackageReader().readPackage(at: inputURL)
            printInspection(summary)
            return 0
        } catch {
            print("Error: \(error.localizedDescription)")
            print("")
            printHelp()
            return 1
        }
    }

    private func buildRecipes(arguments: [String]) -> Int32 {
        do {
            let options = try CLIOptions(arguments: arguments)
            guard let inputPath = options.value(for: "--input") else {
                throw CLIError.missingRequiredOption("--input")
            }

            guard let recipesPath = options.value(for: "--recipes") else {
                throw CLIError.missingRequiredOption("--recipes")
            }

            let seed = options.value(for: "--seed") ?? "debtscope-first-look-v1"
            let inputURL = URL(fileURLWithPath: inputPath).standardizedFileURL
            let recipesURL = URL(fileURLWithPath: recipesPath).standardizedFileURL
            let summary = try BackupPackageReader().readPackage(at: inputURL)
            let builder = SampleRecipeBuilder()
            let recipes = try builder.buildRecipes(from: summary.manifest, seed: seed)
            let result = try builder.writeRecipes(recipes, to: recipesURL)
            let validation = try PrivacyValidator().validateRecipes(
                result.recipes,
                in: recipesURL,
                against: summary.manifest
            )
            printRecipeBuildResult(result, seed: seed, validation: validation)

            if validation.hasFailures && !options.containsFlag("--allow-risky-output") {
                throw PrivacyValidationError.validationFailed(reportURL: validation.reportURL)
            }

            if validation.hasFailures {
                print("")
                print("Risky output allowed by explicit --allow-risky-output flag.")
            }

            return 0
        } catch {
            print("Error: \(error.localizedDescription)")
            print("")
            printHelp()
            return 1
        }
    }

    private func printInspection(_ summary: BackupPackageSummary) {
        let manifest = summary.manifest
        let transactionsByAccount = manifest.transactionCountsByAccountID
        let balancesByAccount = manifest.balanceCountsByAccountID
        let transactionsByBatch = manifest.transactionCountsByBatchID
        let balancesByBatch = manifest.balanceCountsByBatchID

        print("FakePDFGen backup inspection")
        print("Input: \(summary.packageURL.path)")
        print("Manifest version: \(manifest.version)")
        print("Generated at: \(DateFormatter.inspect.string(from: manifest.generatedAt))")
        print("")
        print("Totals")
        print("  Accounts: \(manifest.accounts.count)")
        print("  Import batches: \(manifest.importBatches.count)")
        print("  Transactions: \(manifest.transactions.count)")
        print("  Balance snapshots: \(manifest.balanceSnapshots.count)")
        print("")
        print("Import batches")

        if manifest.importBatches.isEmpty {
            print("  None")
        } else {
            for batch in manifest.importBatches.sorted(by: { $0.createdAt < $1.createdAt }) {
                let id = batch.id.uuidString
                let parser = batch.parserId ?? "unknown-parser"
                let transactionCount = transactionsByBatch[batch.id, default: 0]
                let balanceCount = balancesByBatch[batch.id, default: 0]
                let pdfCount = summary.statementPDFCountsByBatchID[batch.id, default: 0]
                print("  \(id) | \(DateFormatter.inspect.string(from: batch.createdAt)) | parser: \(parser) | transactions: \(transactionCount) | balances: \(balanceCount) | statement PDFs indexed: \(pdfCount)")
            }
        }

        print("")
        print("Accounts")
        if manifest.accounts.isEmpty {
            print("  None")
        } else {
            for account in manifest.accounts.sorted(by: { $0.createdAt < $1.createdAt }) {
                let id = account.id.uuidString
                let transactionCount = transactionsByAccount[account.id, default: 0]
                let balanceCount = balancesByAccount[account.id, default: 0]
                print("  \(id) | type: \(account.typeRaw) | currency: \(account.currencyCode) | transactions: \(transactionCount) | balances: \(balanceCount)")
            }
        }

        print("")
        print("Privacy note: inspect mode does not read live app data, parse statement PDFs, or print payees, memos, source filenames, account names, institutions, or last-four values.")
    }

    private func printRecipeBuildResult(
        _ result: SampleRecipeBuildResult,
        seed: String,
        validation: PrivacyValidationResult
    ) {
        print("FakePDFGen recipe build")
        print("Recipes directory: \(result.outputDirectory.path)")
        print("Seed: \(seed)")
        print("Recipes written: \(result.recipes.count)")

        for recipe in result.recipes {
            print("  \(recipe.fileName) | kind: \(recipe.recipe.statementKind.rawValue) | transactions: \(recipe.recipe.transactions.count)")
        }

        print("")
        print("Privacy validation: \(validation.hasFailures ? "failed" : "passed")")
        print("Validation report: \(validation.reportURL.path)")
        print("Denylist entries checked: \(validation.denylistCount)")
        print("Findings: \(validation.findings.count)")
        print("")
        print("Privacy note: recipe mode writes deterministic fictional values only. It does not parse statement PDFs, copy source filenames, or copy source account, institution, payee, memo, or last-four strings.")
    }

    private func printHelp() {
        print("""
        FakePDFGen

        Generates fictional, importable DebtScope sample statement PDFs from sanitized recipes.

        Usage:
          \(executableName) --help
          \(executableName) inspect --input /path/to/Backup.dsbackup
          \(executableName) build-recipes --input /path/to/Backup.dsbackup --recipes Tools/FakePDFGen/Recipes/generated --seed debtscope-first-look-v1
          \(executableName) render --recipes Tools/FakePDFGen/Recipes/generated --output Tools/FakePDFGen/Output/PDFs
          \(executableName) verify --output Tools/FakePDFGen/Output/PDFs

        Options:
          --input <path>     DebtScope .dsbackup package directory.
          --output <path>    Directory for generated PDF files.
          --recipes <path>   Directory for generated recipe JSON files.
          --seed <value>     Deterministic seed used for fictionalization.
          --allow-risky-output
                            Continue after privacy validation failures.
          --help, -h         Show this help text.

        Inspect mode reads only the provided .dsbackup package directory. It does not touch the live app store or app sandbox.
        """)
    }
}

enum CLIError: LocalizedError {
    case missingRequiredOption(String)
    case missingValue(String)
    case unsupportedOption(String)

    var errorDescription: String? {
        switch self {
        case .missingRequiredOption(let option):
            return "Missing required option: \(option)"
        case .missingValue(let option):
            return "Missing value for option: \(option)"
        case .unsupportedOption(let option):
            return "Unsupported option for this command: \(option)"
        }
    }
}

struct CLIOptions {
    private let values: [String: String]
    private let flags: Set<String>

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--") else {
                throw CLIError.unsupportedOption(option)
            }

            if option == "--allow-risky-output" {
                flags.insert(option)
                index += 1
                continue
            }

            guard index + 1 < arguments.count else {
                throw CLIError.missingValue(option)
            }

            let value = arguments[index + 1]
            guard !value.hasPrefix("--") else {
                throw CLIError.missingValue(option)
            }

            values[option] = value
            index += 2
        }

        self.values = values
        self.flags = flags
    }

    func value(for option: String) -> String? {
        values[option]
    }

    func containsFlag(_ option: String) -> Bool {
        flags.contains(option)
    }
}

private extension DateFormatter {
    static let inspect: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter
    }()
}

let cli = FakePDFGenCLI(executableName: URL(fileURLWithPath: CommandLine.arguments.first ?? "FakePDFGen").lastPathComponent)
exit(cli.run(arguments: CommandLine.arguments))
