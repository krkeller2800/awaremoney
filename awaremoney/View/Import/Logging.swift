import Foundation
import OSLog

/// Unified logging for AwareMoney built on top of Apple's Unified Logging (OSLog/Logger).
///
/// Usage:
///   - AMLogging.log("debug message", component: "ImportViewModel")   // gated by AMLogConfig.verbose
///   - AMLogging.always("important message", component: "Importer")    // always-on notice level
///   - AMLogging.error("error message", component: "Importer")         // error level
///
/// You can toggle verbose debug logs at runtime by setting UserDefaults key `"verbose_logging"` to true.
/// In DEBUG builds, verbose defaults to true if the key is not present; in RELEASE it defaults to false.
enum AMLogConfig {
    #if DEBUG
    private static let verboseDefault: Bool = true
    #else
    private static let verboseDefault: Bool = false
    #endif

    /// Controls whether `AMLogging.log` emits messages. `.always` and `.error` are unaffected.
    static var verbose: Bool {
        get {
            if UserDefaults.standard.object(forKey: "verbose_logging") != nil {
                return UserDefaults.standard.bool(forKey: "verbose_logging")
            }
            return verboseDefault
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "verbose_logging")
        }
    }

    // MARK: - Per-category verbose overrides
    private static let categoriesKey = "verbose_logging_categories"

    /// Returns the current per-category overrides dictionary from UserDefaults.
    private static var verboseCategoryOverrides: [String: Bool] {
        get {
            if let dict = UserDefaults.standard.dictionary(forKey: categoriesKey) as? [String: Bool] {
                return dict
            }
            return [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: categoriesKey)
        }
    }

    /// Whether verbose logging is enabled for a specific category. If an override exists for the category,
    /// it takes precedence; otherwise this falls back to the global `verbose` flag.
    static func isVerboseEnabled(for category: String) -> Bool {
        if let override = verboseCategoryOverrides[category] { return override }
        return verbose
    }

    /// Sets a per-category verbose override.
    static func setVerbose(_ enabled: Bool, for category: String) {
        var dict = verboseCategoryOverrides
        dict[category] = enabled
        verboseCategoryOverrides = dict
    }

    /// Clears all per-category overrides, causing categories to inherit the global `verbose` value.
    static func resetCategoryOverrides() {
        UserDefaults.standard.removeObject(forKey: categoriesKey)
    }

    // MARK: - General category gating (applies to debug and notice)
    /// Whether logging is enabled for a specific category. If an override exists for the category, it takes precedence; otherwise defaults to true.
    static func isCategoryEnabled(for category: String) -> Bool {
        if let override = verboseCategoryOverrides[category] { return override }
        return true
    }

    /// Sets a category enable/disable override.
    static func setCategory(_ enabled: Bool, for category: String) {
        var dict = verboseCategoryOverrides
        dict[category] = enabled
        verboseCategoryOverrides = dict
    }

    // Backward compatibility: map verbose-named helpers to general category gating
//    static func isVerboseEnabled(for category: String) -> Bool { isCategoryEnabled(for: category) }
//    static func setVerbose(_ enabled: Bool, for category: String) { setCategory(enabled, for: category) }

    /// Subsystem used for all Logger instances.
    static var subsystem: String {
        Bundle.main.bundleIdentifier ?? "com.awaremoney.app"
    }
}

enum AMLogging {
    /// Returns a Logger for the given component/category.
    private static func logger(for component: String?) -> Logger {
        let category: String
        if let c = component, !c.isEmpty {
            category = c
        } else {
            category = "General"
        }
        return Logger(subsystem: AMLogConfig.subsystem, category: category)
    }

    /// Debug/verbose logs. Emitted only when `AMLogConfig.verbose` is true.
    static func log(
        _ message: @autoclosure @escaping () -> String,
        component: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let comp = component ?? (file as NSString).lastPathComponent
        guard AMLogConfig.isCategoryEnabled(for: comp) && AMLogConfig.verbose else { return }
        let logger = logger(for: comp)
        logger.debug("\(message()) — \(function, privacy: .public):\(line)")
    }

    /// Always-on informational logs at notice level. Not gated by `AMLogConfig.verbose`.
    static func always(
        _ message: @autoclosure @escaping () -> String,
        component: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let comp = component ?? (file as NSString).lastPathComponent
        guard AMLogConfig.isCategoryEnabled(for: comp) else { return }
        let logger = logger(for: comp)
        logger.notice("\(message()) — \(function, privacy: .public):\(line)")
    }

    /// Error-level logs for user-impacting failures.
    static func error(
        _ message: @autoclosure @escaping () -> String,
        component: String? = nil,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let comp = component ?? (file as NSString).lastPathComponent
        let logger = logger(for: comp)
        logger.error("\(message()) — \(function, privacy: .public):\(line)")
    }
}

