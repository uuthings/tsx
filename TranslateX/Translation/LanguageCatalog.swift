import Foundation
import Observation
import Translation

struct TranslationLanguage: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor @Observable
final class LanguageCatalog {
    private var supportedIdentifiers: [String] = []

    /// Cache service capabilities, not their display names. Resolving labels at
    /// presentation time also handles a language change while load is in flight.
    var languages: [TranslationLanguage] {
        Self.normalizedLanguages(supportedIdentifiers.map { Locale.Language(identifier: $0) })
    }

    func load() async {
        supportedIdentifiers = await Self.supportedLanguageIdentifiers()
    }

    // Editing text can update both menus. Reuse the localized app-wide lists
    // until Apple's catalog or the interface language changes.
    @ObservationIgnored private var preferenceLists: [TranslationSide: (locale: Locale, apple: [String], list: [TranslationLanguage])] = [:]

    func preferenceLanguages(for side: TranslationSide) -> [TranslationLanguage] {
        let locale = L10n.currentLocale
        if let cached = preferenceLists[side], cached.locale == locale, cached.apple == supportedIdentifiers {
            return cached.list
        }
        let asTarget = side == .target
        let identifiers = supportedIdentifiers + Self.commonLanguageIdentifiers
            + DedicatedTranslationLanguages.identifiers(for: .deepL, asTarget: asTarget)
            + DedicatedTranslationLanguages.identifiers(for: .azureTranslator, asTarget: asTarget)
            + GoogleTranslationLanguages.identifiers(asTarget: asTarget)
            + QwenMTTranslationLanguages.identifiers(asTarget: asTarget)
            + TencentTranslationLanguages.identifiers(asTarget: asTarget)
        let list = Self.normalizedLanguages(Set(identifiers).map { Locale.Language(identifier: $0) }, locale: locale)
        preferenceLists[side] = (locale, supportedIdentifiers, list)
        return list
    }

    /// Translation APIs accept mapped codes. General-purpose models receive
    /// the chosen language tag in the translation instructions.
    func languages(for service: TranslationServiceConfiguration?, asTarget: Bool = true) -> [TranslationLanguage] {
        guard let service else { return languages }
        let identifiers: [String]
        switch service.kind {
        case .deepL, .azureTranslator:
            identifiers = DedicatedTranslationLanguages.identifiers(for: service.kind, asTarget: asTarget)
        case .googleCloud:
            identifiers = GoogleTranslationLanguages.identifiers(asTarget: asTarget)
        case .qwenMT:
            identifiers = QwenMTTranslationLanguages.identifiers(asTarget: asTarget)
        case .tencentTranslation:
            identifiers = TencentTranslationLanguages.identifiers(asTarget: asTarget)
        case .openAI, .deepSeek, .openAICompatible, .ollama, .claude, .codex:
            return preferenceLanguages(for: asTarget ? .target : .source)
        }
        return Self.normalizedLanguages(identifiers.map { Locale.Language(identifier: $0) })
    }

    private static let commonLanguageIdentifiers = [
        "zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "pt", "pt-PT", "it", "ru",
        "ar", "hi", "th", "vi", "id", "ms", "nl", "pl", "tr", "uk", "sv", "da", "fi", "nb",
        "cs", "el", "he", "ro", "hu", "bg", "sk", "sl", "hr", "sr", "et", "lv", "lt", "fa",
        "bn", "ta", "te", "ur", "sw", "fil", "ca", "eu", "gl", "is", "ga", "af", "mt", "sq"
    ]

    nonisolated private static func supportedLanguageIdentifiers() async -> [String] {
        let supported = await LanguageAvailability().supportedLanguages
        return supported.map(\.minimalIdentifier)
    }

    /// A single identity for picker values, preferences, detected languages and responses.
    /// Foundation minimizes zh-Hans to zh and zh-Hant to zh-TW; keep the script explicit
    /// for Chinese so the product's Simplified/Traditional distinction stays visible.
    /// For other languages, minimalIdentifier retains meaningful regional distinctions:
    /// en/en-US are aliases, while en-GB and en-AU remain separate identifiers.
    nonisolated static func canonicalIdentifier(_ identifier: String) -> String {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        // "auto" belongs to the input UI, not Foundation's language identifier parser.
        guard !identifier.isEmpty, identifier != "auto" else { return identifier }
        let language = Locale.Language(identifier: Locale.canonicalLanguageIdentifier(from: identifier))
        if language.languageCode?.identifier == "zh" {
            switch language.script?.identifier {
            case "Hans": return "zh-Hans"
            case "Hant": return "zh-Hant"
            default: break
            }
        }
        return language.minimalIdentifier
    }

    /// Concrete language names come from the selected locale. The UI localizes its
    /// separate "Detect language" option; it must not pass that sentinel to Translation.
    nonisolated static func displayName(for identifier: String, locale: Locale = L10n.currentLocale) -> String {
        let canonical = canonicalIdentifier(identifier)
        guard !canonical.isEmpty, canonical != "auto" else { return canonical }
        return locale.localizedString(forIdentifier: canonical) ?? canonical
    }

    /// Normalize only languages supplied by Apple. Canonicalization never inserts a
    /// default language or claims that an unlisted language is supported.
    nonisolated static func normalizedLanguages(
        _ supported: [Locale.Language], locale: Locale = L10n.currentLocale
    ) -> [TranslationLanguage] {
        let identifiers = Set(supported.map { canonicalIdentifier($0.minimalIdentifier) })
        return identifiers.map {
            TranslationLanguage(id: $0, name: displayName(for: $0, locale: locale))
        }.sorted {
            let order = $0.name.compare(
                $1.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: locale
            )
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    nonisolated static func status(source: String, target: String) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(
            from: Locale.Language(identifier: canonicalIdentifier(source)),
            to: Locale.Language(identifier: canonicalIdentifier(target))
        )
    }
}
