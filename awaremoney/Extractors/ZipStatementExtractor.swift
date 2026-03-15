//  ZipStatementExtractor.swift
//  awaremoney
//
//  Extracts supported statement files from a ZIP and delegates to the appropriate extractor.
//  Preference order: PDF > OFX/QFX > QIF > CSV/TSV/TXT.

import Foundation
#if canImport(ZIPFoundation)
  import ZIPFoundation
  #endif

enum ZipImportError: Error { case unreadable, parseFailed }

enum ZipStatementExtractor {
    static func parse(url: URL) throws -> ([[String]], [String]) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // Canonical headers used by CSV pipeline
        let canonicalHeaders = ["date", "description", "amount", "balance", "account"]

        // Create a unique temp directory for extraction
        let tempDir = makeTempDirectory(prefix: "am_zip_extract_")
        AMLogging.log("ZipStatementExtractor: tempDir=\(tempDir.path)", component: "ZipExtractor")

        // Attempt to open and extract the archive using Foundation's Archive API (if available)
        #if canImport(Foundation)
        guard let archive = try? ArchiveCompat.open(url: url) else {
            AMLogging.error("ZipStatementExtractor: unable to open ZIP archive", component: "ZipExtractor")
            return ([], canonicalHeaders)
        }
        do {
            try ArchiveCompat.extractAll(from: archive, to: tempDir)
        } catch {
            AMLogging.error("ZipStatementExtractor: extraction failed — \(error.localizedDescription)", component: "ZipExtractor")
            return ([], canonicalHeaders)
        }
        #else
        return ([], canonicalHeaders)
        #endif

        // Enumerate extracted files and choose the best candidate
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: tempDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            AMLogging.log("ZipStatementExtractor: enumerator unavailable", component: "ZipExtractor")
            return ([], canonicalHeaders)
        }

        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            do {
                let rv = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                if rv.isRegularFile == true { candidates.append(fileURL) }
            } catch { /* ignore unreadable entries */ }
        }

        AMLogging.log("ZipStatementExtractor: extracted file candidates count=\(candidates.count)", component: "ZipExtractor")
        guard let best = bestCandidate(from: candidates) else {
            AMLogging.log("ZipStatementExtractor: no suitable candidate found in ZIP", component: "ZipExtractor")
            return ([], canonicalHeaders)
        }
        AMLogging.log("ZipStatementExtractor: selected candidate=\(best.lastPathComponent)", component: "ZipExtractor")

        // Delegate to appropriate extractor by extension
        let ext = best.pathExtension.lowercased()
        do {
            switch ext {
            case "pdf":
                let (rows, headers) = try PDFStatementExtractor.parse(url: best)
                return (rows, headers)
            case "ofx", "qfx":
                let (rows, headers) = try OFXStatementExtractor.parse(url: best)
                return (rows, headers)
            case "qif":
                let (rows, headers) = try QIFStatementExtractor.parse(url: best)
                return (rows, headers)
            case "csv", "tsv", "txt":
                let (rows, headers) = try CSVStatementExtractor.parse(url: best)
                return (rows, headers)
            default:
                AMLogging.log("ZipStatementExtractor: unsupported inner file extension .\(ext)", component: "ZipExtractor")
                return ([], canonicalHeaders)
            }
        } catch {
            AMLogging.error("ZipStatementExtractor: delegate parse failed — \(error.localizedDescription)", component: "ZipExtractor")
            return ([], canonicalHeaders)
        }
    }
}
// MARK: - Helpers

private func makeTempDirectory(prefix: String) -> URL {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func bestCandidate(from urls: [URL]) -> URL? {
    // Preference order: pdf > ofx > qfx > qif > csv > tsv > txt
    let priority: [String: Int] = [
        "pdf": 0,
        "ofx": 1,
        "qfx": 2,
        "qif": 3,
        "csv": 4,
        "tsv": 5,
        "txt": 6
    ]
    return urls
        .filter { !$0.lastPathComponent.hasPrefix(".") }
        .sorted { (lhs, rhs) -> Bool in
            let le = lhs.pathExtension.lowercased()
            let re = rhs.pathExtension.lowercased()
            let lp = priority[le] ?? Int.max
            let rp = priority[re] ?? Int.max
            if lp == rp { return lhs.lastPathComponent < rhs.lastPathComponent }
            return lp < rp
        }
        .first
}

// MARK: - Minimal Archive compatibility layer
// This wrapper allows us to use a ZIP archive reader if available without introducing a third-party dependency.
// In recent SDKs, Foundation provides an Archive type for ZIPs; otherwise these helpers will fail gracefully.

private enum ArchiveCompat {
    // Abstract types so we don't expose unknown concrete types to the compiler in case APIs differ.
    struct AnyArchive { let raw: Any }

    static func open(url: URL) throws -> AnyArchive? {
        // Fallback: attempt direct ZIPFoundation API if it is available at compile time
        #if canImport(ZIPFoundation)
        if let archive = Archive(url: url, accessMode: .read) { return AnyArchive(raw: archive) }
        else { return nil }
        #else
        return nil
        #endif
    }

    static func extractAll(from archive: AnyArchive, to directory: URL) throws {
        // Attempt to use ZIPFoundation-like API via dynamic dispatch
        let mirror = Mirror(reflecting: archive.raw)
        if String(describing: mirror.subjectType).contains("Archive") {
            // Try to iterate entries via KVC and call extract(entry:to:)
            if let entries = (archive.raw as AnyObject).value(forKey: "entries") as? [Any] {
                for entry in entries {
                    // Each entry is expected to have properties: path, type
                    let obj = entry as AnyObject
                    let type = (obj.value(forKey: "type") as AnyObject?)?.description ?? "file"
                    if type.lowercased().contains("directory") { continue }
                    let path = (obj.value(forKey: "path") as? String) ?? UUID().uuidString
                    let dest = directory.appendingPathComponent(path)
                    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    // Try calling extract
                    _ = (archive.raw as AnyObject).perform(NSSelectorFromString("extract:to:"), with: entry, with: dest)
                }
                return
            }
        }
        throw ZipImportError.parseFailed
    }
}

