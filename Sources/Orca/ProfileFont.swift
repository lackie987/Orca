import Foundation

/// Reads the text font from the active dsh profile so the startup page matches the app.
enum ProfileFont {
    /// Resolves the configured text font stack, or nil when the profile is unreadable.
    static func family(profile: String) -> String? {
        let home = ProcessInfo.processInfo.environment["DSH_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh").path
        let patch = URL(fileURLWithPath: home)
            .appendingPathComponent("profiles")
            .appendingPathComponent(profile)
            .appendingPathComponent("cordis.patch.yml")
        guard let text = try? String(contentsOf: patch, encoding: .utf8) else { return nil }
        for key in ["textFontFamily", "fontFamily", "mono", "stackDialog"] {
            if let value = value(of: key, in: text) { return value }
        }
        return nil
    }

    /// Last scalar value for `key`, with YAML's outer quotes and comments removed.
    private static func value(of key: String, in text: String) -> String? {
        let pattern = "(?m)^\\s*\(key):\\s*(.+?)\\s*$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: String?
        for match in regex.matches(in: text, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: text) else { continue }
            var value = String(text[valueRange])
            if let comment = value.range(of: " #") { value = String(value[..<comment.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                value = value.replacingOccurrences(of: "''", with: "'")
            }
            if !value.isEmpty { result = value }
        }
        return result
    }
}
