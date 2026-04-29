import UniformTypeIdentifiers

extension UTType {
    static let debtScopeBackup: UTType = {
        // Prefer Info.plist declared type if available
        if let declared = UTType("com.komakode.debtscope.backup") {
            return declared
        }
        // Fallback: map by extension as a PACKAGE (not JSON)
        if let byTag = UTType(tag: "dsbackup", tagClass: .filenameExtension, conformingTo: .package) {
            return byTag
        }
        // Last resort: export a package type
        return UTType(exportedAs: "com.komakode.debtscope.backup", conformingTo: .package)
    }()

    static var debtScopeBackupByExtension: UTType? {
        UTType(tag: "dsbackup", tagClass: .filenameExtension, conformingTo: .package)
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
