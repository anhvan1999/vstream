import Foundation

/// A language as files and addons spell it: mpv track tags and OpenSubtitles use ISO 639-2
/// (both B and T forms), some addons use 639-1 or region-specific codes.
public struct LanguageOption: Identifiable, Hashable, Sendable {
    public var id: String { codes[0] }
    public var name: String
    public var codes: [String]
}

public enum Languages {
    public static let all: [LanguageOption] = [
        .init(name: "English", codes: ["eng", "en"]),
        .init(name: "Vietnamese", codes: ["vie", "vi"]),
        .init(name: "Japanese", codes: ["jpn", "ja"]),
        .init(name: "Korean", codes: ["kor", "ko"]),
        .init(name: "Chinese", codes: ["chi", "zho", "zh", "zh-cn", "zh-tw", "chs", "cht"]),
        .init(name: "Thai", codes: ["tha", "th"]),
        .init(name: "Indonesian", codes: ["ind", "id"]),
        .init(name: "Malay", codes: ["may", "msa", "ms"]),
        .init(name: "Filipino", codes: ["fil", "tl"]),
        .init(name: "Hindi", codes: ["hin", "hi"]),
        .init(name: "Arabic", codes: ["ara", "ar"]),
        .init(name: "French", codes: ["fre", "fra", "fr"]),
        .init(name: "Spanish", codes: ["spa", "es", "spl", "es-419"]),
        .init(name: "Portuguese", codes: ["por", "pt"]),
        .init(name: "Portuguese (Brazil)", codes: ["pob", "pt-br"]),
        .init(name: "German", codes: ["ger", "deu", "de"]),
        .init(name: "Italian", codes: ["ita", "it"]),
        .init(name: "Dutch", codes: ["dut", "nld", "nl"]),
        .init(name: "Russian", codes: ["rus", "ru"]),
        .init(name: "Ukrainian", codes: ["ukr", "uk"]),
        .init(name: "Polish", codes: ["pol", "pl"]),
        .init(name: "Turkish", codes: ["tur", "tr"]),
        .init(name: "Swedish", codes: ["swe", "sv"]),
        .init(name: "Norwegian", codes: ["nor", "nob", "no", "nb"]),
        .init(name: "Danish", codes: ["dan", "da"]),
        .init(name: "Finnish", codes: ["fin", "fi"]),
        .init(name: "Greek", codes: ["gre", "ell", "el"]),
        .init(name: "Hebrew", codes: ["heb", "he"]),
        .init(name: "Czech", codes: ["cze", "ces", "cs"]),
        .init(name: "Hungarian", codes: ["hun", "hu"]),
        .init(name: "Romanian", codes: ["rum", "ron", "ro"]),
    ]

    private static let byCode: [String: LanguageOption] = {
        var map: [String: LanguageOption] = [:]
        for option in all { for code in option.codes { map[code] = option } }
        return map
    }()

    public static func option(for code: String?) -> LanguageOption? {
        guard let code = code?.lowercased(), !code.isEmpty else { return nil }
        return byCode[code] ?? byCode[String(code.prefix(3))]
    }

    /// Human-readable name for any code, falling back to the system's localisation.
    public static func name(for code: String?) -> String {
        guard let code, !code.isEmpty else { return "Unknown" }
        if let option = option(for: code) { return option.name }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    public static func matches(_ code: String?, any preferred: [String]) -> Bool {
        guard let code = code?.lowercased() else { return false }
        if preferred.contains(code) { return true }
        guard let option = option(for: code) else { return false }
        return !Set(option.codes).isDisjoint(with: preferred)
    }
}
