import UniformTypeIdentifiers

extension UTType {
    /// The custom type identifier for AwareMoney backup files.
    /// Declared in Info.plist (UTExportedTypeDeclarations) with filename extension ".ambackup".
    static let awareMoneyBackup: UTType = {
        // Prefer an Info.plist-declared type if available
        if let declared = UTType("com.komakode.awaremoney.backup") {
            return declared
        }
        // Fall back to a tag-based type so the file picker recognizes .ambackup files
        if let byTag = UTType(tag: "ambackup", tagClass: .filenameExtension, conformingTo: .json) {
            return byTag
        }
        // As a last resort, create an exported type (no tag mapping without Info.plist)
        return UTType(exportedAs: "com.komakode.awaremoney.backup", conformingTo: .json)
    }()
    
    static var awareMoneyBackupByExtension: UTType? {
        UTType(tag: "ambackup", tagClass: .filenameExtension, conformingTo: .json)
    }
    
    // Additional statement/document types supported by the import pipeline
    static var ofx: UTType? { UTType(tag: "ofx", tagClass: .filenameExtension, conformingTo: .data) }
    static var qfx: UTType? { UTType(tag: "qfx", tagClass: .filenameExtension, conformingTo: .data) }
    static var qif: UTType? { UTType(tag: "qif", tagClass: .filenameExtension, conformingTo: .text) }
    static var xlsx: UTType? { UTType(tag: "xlsx", tagClass: .filenameExtension, conformingTo: .data) }
    static var xls: UTType? { UTType(tag: "xls", tagClass: .filenameExtension, conformingTo: .data) }
    static var zip: UTType? { UTType(tag: "zip", tagClass: .filenameExtension, conformingTo: .data) }
    static var tsv: UTType? { UTType(tag: "tsv", tagClass: .filenameExtension, conformingTo: .text) }
}
