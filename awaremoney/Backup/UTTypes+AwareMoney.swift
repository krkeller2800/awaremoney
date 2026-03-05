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
}
