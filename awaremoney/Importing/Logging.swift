import Foundation

/// Global logging utility for debug output.
/// Toggle `isEnabled` to enable/disable logs app-wide.
/// Usage: `AMLogging.log("message", component: "SomeComponent")`
enum AMLogging {
    /// Hardcoded gate to turn logging on/off.
    /// Set to `false` to silence all AMLogging output.
    #if DEBUG
    static let isEnabled: Bool = false
    #else
    static let isEnabled: Bool = false
    #endif
    /// Emits a debug log if `isEnabled` is true. Automatically includes file/function/line for context.
    static func log(
        _ message: @autoclosure () -> String,
        component: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        guard isEnabled else { return }
        let comp = component ?? (file as NSString).lastPathComponent
        // Identifying tag: [AM][Component] and a trailing code comment marker for easy grep: DEBUG LOG
        print("[AM][\(comp)] \(message()) — \(function):\(line)  // DEBUG LOG")
    }

    static func always(
        _ message: @autoclosure () -> String,
        component: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let comp = component ?? (file as NSString).lastPathComponent
        print("[AM][\(comp)] \(message()) — \(function):\(line)  // ALWAYS LOG")
    }
}
