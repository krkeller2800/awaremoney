import SwiftUI
import Combine

/// An ObservableObject that routes incoming file URLs opened from outside the app.
final class ImportOpenRouter: ObservableObject {
    /// The URL of a file pending to be imported or processed.
    @Published var pendingURL: URL? = nil
    
    /// Public initializer.
    public init() {}
    
    /// Clears the pending URL.
    public func clearPendingURL() {
        pendingURL = nil
    }
}
