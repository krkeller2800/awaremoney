import UniformTypeIdentifiers

extension UTType {
    static let debtScopeFlatBackupExtensions = ["ambackup", "debtscopebackup"]
    static let debtScopePackageBackupExtensions = ["dsbackup"]
    static let debtScopeBackupExtensions = debtScopeFlatBackupExtensions + debtScopePackageBackupExtensions

    static let debtScopeBackup: UTType = {
        // Prefer Info.plist declared type if available
        if let declared = UTType("com.komakode.debtscope.backup") {
            return declared
        }
        // Fallback by known extensions. Shared backups are regular JSON files;
        // exported backups may still arrive as directories and are handled by the importer.
        if let byTag = debtScopeBackupByExtension {
            return byTag
        }
        return UTType(exportedAs: "com.komakode.debtscope.backup", conformingTo: .data)
    }()

    static let debtScopeBackupPackage: UTType = {
        if let declared = UTType("com.komakode.debtscope.backup-package") {
            return declared
        }
        if let byTag = UTType(tag: "dsbackup", tagClass: .filenameExtension, conformingTo: .package) {
            return byTag
        }
        return UTType(exportedAs: "com.komakode.debtscope.backup-package", conformingTo: .package)
    }()

    static var debtScopeBackupByExtension: UTType? {
        debtScopeBackupExtensions.lazy.compactMap {
            UTType(tag: $0, tagClass: .filenameExtension, conformingTo: .data)
        }.first
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
