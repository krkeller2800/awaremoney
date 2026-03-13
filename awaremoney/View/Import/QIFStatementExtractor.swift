//  QIFStatementExtractor.swift
//  awaremoney
//
//  Stub extractor for QIF files. Converts parsed content into a CSV-like rows/headers pair
//  compatible with the existing StatementParser pipeline.

import Foundation

enum QIFImportError: Error { case unreadable, parseFailed }

enum QIFStatementExtractor {
    /// Parses a QIF file into (rows, headers) using a simple CSV-like schema.
    /// This is a stub implementation that returns an empty result for now.
    /// Replace with a real QIF parser that extracts transactions.
    static func parse(url: URL) throws -> ([[String]], [String]) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        let headers = ["date", "description", "amount", "balance", "account"]
        let rows: [[String]] = []
        return (rows, headers)
    }
}
