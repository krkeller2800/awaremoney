import SwiftUI
import Combine
import Foundation

/// An ObservableObject that routes incoming file URLs opened from outside the app.
final class ImportOpenRouter: ObservableObject {
    struct QuickStartImportRequest: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let type: StatementType?
        let institution: String?
    }

    /// Optional type hint supplied by an upstream intake flow (e.g., Quick Start)
    @Published var pendingType: StatementType? = nil

    /// Optional institution hint supplied by an upstream intake flow
    @Published var pendingInstitution: String? = nil

    /// Clears the pending URL and any associated hints
    public func clearPending() {
        pendingURL = nil
        pendingType = nil
        pendingInstitution = nil
        quickStartPendingImport = nil
    }

    /// The URL of a file pending to be imported or processed.
    @Published var pendingURL: URL? = nil

    /// Durable Quick Start import request used for Files/share-sheet intake routing.
    @Published var quickStartPendingImport: QuickStartImportRequest? = nil
    
    /// Public initializer.
    public init() {}
    
    /// Clears the pending URL.
    public func clearPendingURL() {
        pendingURL = nil
    }
}
