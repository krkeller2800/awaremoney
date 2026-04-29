import SwiftUI

// A harmless shim to satisfy helper references in QuickStart.
// This does NOT attempt to fetch environment objects; it always returns nil.
extension AnyView {
    func environmentObject<T>(_ type: T.Type) -> Any? { nil }
}
