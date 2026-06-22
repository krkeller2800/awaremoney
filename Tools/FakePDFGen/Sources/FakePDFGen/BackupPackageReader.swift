import Foundation

struct BackupPackageSummary {
    let packageURL: URL
    let manifest: BackupManifest
    let statementPDFCountsByBatchID: [UUID: Int]
}

enum BackupPackageReaderError: LocalizedError {
    case inputMissing(String)
    case inputIsNotDirectory(String)
    case manifestMissing(String)
    case manifestInvalid(String)

    var errorDescription: String? {
        switch self {
        case .inputMissing(let path):
            return "Input package does not exist: \(path)"
        case .inputIsNotDirectory(let path):
            return "Input must be a .dsbackup package directory: \(path)"
        case .manifestMissing(let path):
            return "Could not find manifest.json in backup package: \(path)"
        case .manifestInvalid(let detail):
            return "Could not decode manifest.json: \(detail)"
        }
    }
}

struct BackupPackageReader {
    func readPackage(at inputURL: URL) throws -> BackupPackageSummary {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
            throw BackupPackageReaderError.inputMissing(inputURL.path)
        }

        guard isDirectory.boolValue else {
            throw BackupPackageReaderError.inputIsNotDirectory(inputURL.path)
        }

        let manifestURL = inputURL.appendingPathComponent("manifest.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw BackupPackageReaderError.manifestMissing(inputURL.path)
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try Self.decodeDate(decoder: decoder)
        }

        let manifest: BackupManifest
        do {
            manifest = try decoder.decode(BackupManifest.self, from: manifestData)
        } catch {
            throw BackupPackageReaderError.manifestInvalid(error.localizedDescription)
        }

        return BackupPackageSummary(
            packageURL: inputURL,
            manifest: manifest,
            statementPDFCountsByBatchID: indexStatementPDFs(in: inputURL)
        )
    }

    private func indexStatementPDFs(in packageURL: URL) -> [UUID: Int] {
        let fileManager = FileManager.default
        let statementsURL = packageURL.appendingPathComponent("statements", isDirectory: true)

        guard let batchDirectories = try? fileManager.contentsOfDirectory(
            at: statementsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var counts: [UUID: Int] = [:]
        for batchDirectory in batchDirectories {
            guard UUID(uuidString: batchDirectory.lastPathComponent) != nil else {
                continue
            }

            let pdfCount = ((try? fileManager.contentsOfDirectory(
                at: batchDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension.lowercased() == "pdf" }.count

            if let batchID = UUID(uuidString: batchDirectory.lastPathComponent), pdfCount > 0 {
                counts[batchID] = pdfCount
            }
        }

        return counts
    }

    private static func decodeDate(decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        if let date = ISO8601DateFormatter.standard.date(from: value) {
            return date
        }

        if let date = ISO8601DateFormatter.fractionalSeconds.date(from: value) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO-8601 date: \(value)"
        )
    }
}

private extension ISO8601DateFormatter {
    static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let fractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
