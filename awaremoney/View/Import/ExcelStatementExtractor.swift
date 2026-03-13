//  ExcelStatementExtractor.swift
//  awaremoney
//
//  Minimal XLSX reader: extracts the first worksheet into a CSV-like (rows, headers) pair
//  so it can flow through the existing StatementParser pipeline. This avoids third-party
//  dependencies by implementing a tiny ZIP reader sufficient for .xlsx (OpenXML) files
//  and parsing the key XML parts we need.
//
//  Notes/Limitations:
//  - Reads only .xlsx (Open XML). Legacy .xls (BIFF) is not supported.
//  - Loads the first worksheet (xl/worksheets/sheet*.xml). If multiple sheets exist,
//    the numerically first one is chosen (sheet1 before sheet2, etc.).
//  - Handles shared strings (xl/sharedStrings.xml) for cell type t="s".
//  - Handles inline strings (t="inlineStr"). Other types are read as raw text.
//  - Returns the first non-empty row as headers; remaining rows as data. If the first row
//    is empty or missing, synthetic headers (Column 1, Column 2, …) are generated.
//  - Best-effort and intentionally conservative; it’s easy to extend later.

import Foundation
import Compression

enum ExcelImportError: Error, LocalizedError {
    case unreadable
    case parseFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The Excel file couldn’t be read."
        case .parseFailed(let msg): return "Excel parse failed: \(msg)"
        case .unsupported(let msg): return "Excel unsupported: \(msg)"
        }
    }
}

enum ExcelStatementExtractor {
    /// Parses an Excel .xlsx file into (rows, headers) using a CSV-like schema.
    /// - Returns: A tuple of (rows, headers). Headers come from the first non-empty row, or are synthesized.
    static func parse(url: URL) throws -> ([[String]], [String]) {
        let ext = url.pathExtension.lowercased()
        guard ext == "xlsx" else {
            // We don’t support legacy .xls in this minimal reader
            throw ExcelImportError.unsupported("Only .xlsx is supported in this build. Export to CSV or .xlsx.")
        }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw ExcelImportError.unreadable
        }

        // Extract required parts from the XLSX (ZIP) container
        let zip = try ZipReader(data: data)
        // Prefer sheet1.xml; otherwise pick the lexicographically first worksheet
        let worksheetPath = zip.firstExistingEntry([
            "xl/worksheets/sheet1.xml"
        ]) ?? zip.firstWorksheetPath()
        guard let sheetPath = worksheetPath else {
            throw ExcelImportError.parseFailed("No worksheet XML found in workbook.")
        }

        let sharedStringsXML = try? zip.readFile("xl/sharedStrings.xml")
        let sheetXML = try zip.readFile(sheetPath)

        // Parse shared strings (optional)
        let sharedStrings: [String] = {
            if let s = sharedStringsXML { return SharedStringsParser.parse(xml: s) }
            return []
        }()

        // Parse the worksheet into a sparse row/column map, then materialize to 2D array
        let rows = WorksheetParser.parse(xml: sheetXML, sharedStrings: sharedStrings)

        // Determine headers: use first non-empty row as headers; otherwise synthesize
        let headers: [String]
        var dataRows: [[String]] = rows
        if let first = rows.first(where: { row in row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) }) {
            headers = first
            // Drop exactly the first row from the original sequence
            var dropped = false
            dataRows = rows.compactMap { r in
                if !dropped && r == first { dropped = true; return nil }
                return r
            }
        } else {
            // Synthesize headers based on the widest row
            let width = rows.map { $0.count }.max() ?? 0
            headers = (0..<width).map { "Column \($0 + 1)" }
            dataRows = rows
        }

        return (dataRows, headers)
    }
}
// MARK: - Tiny ZIP reader (deflate + stored)

private struct ZipReader {
    private let data: Data

    init(data: Data) throws {
        self.data = data
        // Basic sanity check: must contain End Of Central Directory signature
        guard findEOCD() != nil else { throw ExcelImportError.parseFailed("Not a ZIP container") }
    }

    // Public API: read a file by its path inside the ZIP
    func readFile(_ path: String) throws -> Data {
        guard let entry = try locateEntry(path: path) else {
            throw ExcelImportError.parseFailed("Missing entry: \(path)")
        }
        return try readEntry(entry)
    }

    // Try a list of paths and return the first that exists
    func firstExistingEntry(_ candidates: [String]) -> String? {
        for p in candidates {
            if (try? locateEntry(path: p)) != nil { return p }
        }
        return nil
    }

    // Return the lexicographically first worksheet path if any exist
    func firstWorksheetPath() -> String? {
        let entries = (try? listEntries()) ?? []
        let sheets = entries.filter { $0.hasPrefix("xl/worksheets/") && $0.hasSuffix(".xml") }
        return sheets.sorted().first
    }

    // MARK: ZIP parsing

    private struct CentralDirectoryEntry {
        let name: String
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let compressionMethod: UInt16 // 0 = stored, 8 = deflate
        let localHeaderOffset: UInt32
    }

    private struct EOCD {
        let centralDirectoryOffset: UInt32
        let totalEntries: UInt16
    }

    private func listEntries() throws -> [String] {
        let eocd = try requireEOCD()
        var offset = Int(eocd.centralDirectoryOffset)
        var names: [String] = []
        for _ in 0..<eocd.totalEntries {
            guard readUInt32(at: offset) == 0x02014b50 else { break } // Central file header
            // Skip fixed fields we don’t need; parse sizes and name length
            // Structure (partial):
            //  0  uint32 signature
            //  4  uint16 version made by
            //  6  uint16 version needed
            //  8  uint16 flags
            // 10  uint16 compression method
            // 12  uint16 mod time
            // 14  uint16 mod date
            // 16  uint32 crc32
            // 20  uint32 compressed size
            // 24  uint32 uncompressed size
            // 28  uint16 file name length
            // 30  uint16 extra field length
            // 32  uint16 file comment length
            // 34  uint16 disk number start
            // 36  uint16 internal attrs
            // 38  uint32 external attrs
            // 42  uint32 local header offset
            let compression = readUInt16(at: offset + 10)
            let compSize = readUInt32(at: offset + 20)
            let uncompSize = readUInt32(at: offset + 24)
            let nameLen = Int(readUInt16(at: offset + 28))
            let extraLen = Int(readUInt16(at: offset + 30))
            let commentLen = Int(readUInt16(at: offset + 32))
            let localOff = readUInt32(at: offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLen <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            names.append(name)
            // Advance to next central directory entry
            offset = nameStart + nameLen + extraLen + commentLen
            _ = compression; _ = compSize; _ = uncompSize; _ = localOff
        }
        return names
    }

    private func locateEntry(path: String) throws -> CentralDirectoryEntry? {
        let eocd = try requireEOCD()
        var offset = Int(eocd.centralDirectoryOffset)
        for _ in 0..<eocd.totalEntries {
            guard readUInt32(at: offset) == 0x02014b50 else { break }
            let compression = readUInt16(at: offset + 10)
            let compSize = readUInt32(at: offset + 20)
            let uncompSize = readUInt32(at: offset + 24)
            let nameLen = Int(readUInt16(at: offset + 28))
            let extraLen = Int(readUInt16(at: offset + 30))
            let commentLen = Int(readUInt16(at: offset + 32))
            let localOff = readUInt32(at: offset + 42)
            let nameStart = offset + 46
            guard nameStart + nameLen <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            if name == path {
                return CentralDirectoryEntry(
                    name: name,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    compressionMethod: compression,
                    localHeaderOffset: localOff
                )
            }
            offset = nameStart + nameLen + extraLen + commentLen
        }
        return nil
    }

    private func readEntry(_ e: CentralDirectoryEntry) throws -> Data {
        let offset = Int(e.localHeaderOffset)
        guard readUInt32(at: offset) == 0x04034b50 else {
            throw ExcelImportError.parseFailed("Invalid local file header for \(e.name)")
        }
        let nameLen = Int(readUInt16(at: offset + 26))
        let extraLen = Int(readUInt16(at: offset + 28))
        let dataStart = offset + 30 + nameLen + extraLen
        let compSize = Int(e.compressedSize)
        guard dataStart + compSize <= data.count else {
            throw ExcelImportError.parseFailed("Corrupt data range for \(e.name)")
        }
        let compData = data.subdata(in: dataStart..<(dataStart + compSize))
        switch e.compressionMethod {
        case 0: // stored
            return compData
        case 8: // deflate
            return try inflateDeflate(compData, expectedSize: Int(e.uncompressedSize))
        default:
            throw ExcelImportError.parseFailed("Unsupported compression method \(e.compressionMethod) for \(e.name)")
        }
    }

    private func inflateDeflate(_ input: Data, expectedSize: Int) throws -> Data {
        // Use the built-in Compression framework (zlib/deflate)
        return try input.withUnsafeBytes { (srcPtr: UnsafeRawBufferPointer) -> Data in
            guard let srcBase = srcPtr.baseAddress else { throw ExcelImportError.parseFailed("No input bytes") }
            // Start with expected size; grow if needed
            var dstCapacity = max(expectedSize, 1024)
            var dstData = Data(count: dstCapacity)
            var status: compression_status = COMPRESSION_STATUS_ERROR
            var finalSize = 0
            while true {
                let written = dstData.withUnsafeMutableBytes { dstPtr -> Int in
                    guard let dstBase = dstPtr.baseAddress else { return 0 }
                    let size = compression_decode_buffer(
                        dstBase.assumingMemoryBound(to: UInt8.self),
                        dstCapacity,
                        srcBase.assumingMemoryBound(to: UInt8.self),
                        input.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                    return size
                }
                if written == 0 {
                    // Increase capacity and retry
                    dstCapacity *= 2
                    dstData.count = dstCapacity
                    continue
                } else {
                    finalSize = written
                    status = COMPRESSION_STATUS_OK
                    break
                }
            }
            if status != COMPRESSION_STATUS_OK { throw ExcelImportError.parseFailed("Inflate failed") }
            dstData.count = finalSize
            return dstData
        }
    }

    private func requireEOCD() throws -> EOCD {
        if let e = findEOCD() { return e }
        throw ExcelImportError.parseFailed("ZIP End Of Central Directory not found")
    }

    private func findEOCD() -> EOCD? {
        // EOCD signature 0x06054b50 at the end; search backwards up to 65KB
        let sig: UInt32 = 0x06054b50
        let maxSearch = min(data.count, 22 + 65535)
        var idx = data.count - 22
        let stop = data.count - maxSearch
        while idx >= max(stop, 0) {
            if readUInt32(at: idx) == sig {
                // Structure:
                //  0  uint32 signature
                //  4  uint16 disk number
                //  6  uint16 disk with central dir
                //  8  uint16 entries on this disk
                // 10  uint16 total entries
                // 12  uint32 central dir size
                // 16  uint32 central dir offset
                // 20  uint16 comment length
                let total = readUInt16(at: idx + 10)
                let cdOffset = readUInt32(at: idx + 16)
                return EOCD(centralDirectoryOffset: cdOffset, totalEntries: total)
            }
            idx -= 1
        }
        return nil
    }

    // MARK: - Little-endian readers

    private func readUInt16(at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let b0 = UInt16(base[offset])
            let b1 = UInt16(base[offset + 1]) << 8
            return b0 | b1
        }
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let b0 = UInt32(base[offset])
            let b1 = UInt32(base[offset + 1]) << 8
            let b2 = UInt32(base[offset + 2]) << 16
            let b3 = UInt32(base[offset + 3]) << 24
            return b0 | b1 | b2 | b3
        }
    }
}

// MARK: - Shared strings parser

private enum SharedStringsParser {
    static func parse(xml: Data) -> [String] {
        let delegate = ParserDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.items
    }

    private class ParserDelegate: NSObject, XMLParserDelegate {
        var items: [String] = []
        private var buffer: String = ""
        private var inText = false
        private var inSI = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
            if elementName == "si" { inSI = true; buffer = "" }
            if elementName == "t" && inSI { inText = true }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inText { buffer.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "t" { inText = false }
            if elementName == "si" { items.append(buffer); buffer = ""; inSI = false }
        }
    }
}

// MARK: - Worksheet parser

private enum WorksheetParser {
    static func parse(xml: Data, sharedStrings: [String]) -> [[String]] {
        let delegate = WorksheetParserImpl(shared: sharedStrings)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return delegate.materialize()
    }

    private class WorksheetParserImpl: NSObject, XMLParserDelegate {
        let shared: [String]
        // Sparse representation: row index -> [colIndex: String]
        var rows: [Int: [Int: String]] = [:]
        var maxCol: Int = 0
        var currentRow: Int = -1
        var currentCol: Int = -1
        var currentType: String? = nil // cell @t
        var collectingV = false
        var collectingInlineT = false
        var textBuffer: String = ""

        init(shared: [String]) { self.shared = shared }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attrs: [String : String] = [:]) {
            switch name {
            case "row":
                if let rStr = attrs["r"], let r = Int(rStr) { currentRow = r - 1 } else { currentRow += 1 }
            case "c":
                // cell reference like "C5" -> column index
                currentType = attrs["t"]
                if let r = attrs["r"], let col = columnIndex(fromA1: r) { currentCol = col } else { currentCol += 1 }
            case "v":
                collectingV = true; textBuffer = ""
            case "is":
                // inlineStr container; the text lives inside <t>
                break
            case "t":
                // Could be inline string text when parent is <is>
                collectingInlineT = true; textBuffer = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collectingV || collectingInlineT { textBuffer.append(string) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch name {
            case "v":
                let raw = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                assignCell(valueFromV: raw)
                collectingV = false; textBuffer = ""
            case "t":
                if collectingInlineT {
                    let raw = textBuffer
                    assignInlineString(raw)
                    collectingInlineT = false; textBuffer = ""
                }
            case "c":
                currentCol = -1; currentType = nil
            case "row":
                currentRow = -1
            default:
                break
            }
        }

        private func assignCell(valueFromV raw: String) {
            let value: String
            if currentType == "s" { // shared string index
                if let idx = Int(raw), idx >= 0, idx < shared.count { value = shared[idx] } else { value = "" }
            } else {
                value = raw
            }
            store(value)
        }

        private func assignInlineString(_ raw: String) {
            store(raw)
        }

        private func store(_ value: String) {
            guard currentRow >= 0, currentCol >= 0 else { return }
            var row = rows[currentRow] ?? [:]
            row[currentCol] = value
            rows[currentRow] = row
            if currentCol > maxCol { maxCol = currentCol }
        }

        func materialize() -> [[String]] {
            guard !rows.isEmpty else { return [] }
            let maxRow = rows.keys.max() ?? 0
            var result: [[String]] = []
            result.reserveCapacity(maxRow + 1)
            for r in 0...maxRow {
                let map = rows[r] ?? [:]
                var line: [String] = Array(repeating: "", count: maxCol + 1)
                for (c, v) in map { if c >= 0 && c < line.count { line[c] = v } }
                result.append(line)
            }
            // Trim trailing empty columns for a cleaner header/rows result
            let trimmedWidth = computeTrimmedWidth(result)
            if trimmedWidth > 0 {
                result = result.map { Array($0.prefix(trimmedWidth)) }
            }
            // Drop leading completely empty rows
            while let first = result.first, first.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                result.removeFirst()
            }
            return result
        }

        private func computeTrimmedWidth(_ rows: [[String]]) -> Int {
            var width = 0
            for row in rows {
                for (i, v) in row.enumerated() where !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if i + 1 > width { width = i + 1 }
                }
            }
            return width
        }

        private func columnIndex(fromA1 ref: String) -> Int? {
            // Extract the letter part from an A1 reference (e.g., "C5" -> "C")
            let letters = ref.prefix { ch in
                (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z")
            }
            if letters.isEmpty { return nil }
            var idx = 0
            for ch in letters.uppercased() {
                let v = Int(ch.asciiValue! - Character("A").asciiValue! + 1)
                idx = idx * 26 + v
            }
            return idx - 1 // zero-based
        }
    }
}

