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
          --help, -h         Show this help text.

        This step-one scaffold does not read backups, app data, or private folders.
        """)
    }
}

let cli = FakePDFGenCLI(executableName: URL(fileURLWithPath: CommandLine.arguments.first ?? "FakePDFGen").lastPathComponent)
exit(cli.run(arguments: CommandLine.arguments))
