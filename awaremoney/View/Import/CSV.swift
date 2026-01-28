//
//  CSV.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation

enum CSV {
    static func read(data: Data, encoding: String.Encoding = .utf8) throws -> (rows: [[String]], headers: [String]) {
        guard let s = String(data: data, encoding: encoding) else {
            throw ImportError.invalidCSV
        }
        let rows = parse(csv: s)

        // Find the first non-blank row to treat as the header. A blank row is one where all fields are empty/whitespace.
        func isBlankRow(_ row: [String]) -> Bool {
            return row.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard let headerIndex = rows.firstIndex(where: { !isBlankRow($0) }) else {
            throw ImportError.invalidCSV
        }

        let rawHeader = rows[headerIndex]
        let header = rawHeader.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Body is all rows after the header, excluding blank rows
        let tail = rows.dropFirst(headerIndex + 1)
        let body = tail.filter { !isBlankRow($0) }

        return (body, header)
    }

    // Simple CSV parser with quote handling
    private static func parse(csv: String) -> [[String]] {
        var result: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = csv.startIndex

        func finishField() {
            row.append(field)
            field = ""
        }
        func finishRow() {
            result.append(row)
            row = []
        }

        while i < csv.endIndex {
            let ch = csv[i]
            if ch == "\"" {
                if inQuotes {
                    // Peek next
                    let next = csv.index(after: i)
                    if next < csv.endIndex && csv[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            } else if ch == "," && !inQuotes {
                finishField()
            } else if (ch == "\n" || ch == "\r\n" || ch == "\r") && !inQuotes {
                finishField()
                finishRow()
            } else {
                field.append(ch)
            }
            i = csv.index(after: i)
        }
        // Flush last field/row
        finishField()
        if !row.isEmpty {
            finishRow()
        }
        return result.filter { !$0.isEmpty }
    }
}
