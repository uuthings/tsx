import Foundation
import Observation

enum AppAppearance: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

enum AppMaterial: String, Codable, CaseIterable, Sendable {
    case light
    case glass
}

enum HoverCursor: String, Codable, CaseIterable, Sendable {
    case pointingHand
    case arrow
}

enum TranslationLayout: String, Codable, CaseIterable, Sendable {
    case sideBySide
    case stacked

    func defaultSize(for window: TranslationWindowKind) -> CGSize {
        switch (window, self) {
        case (.main, .sideBySide): CGSize(width: 980, height: 598)
        case (.main, .stacked): CGSize(width: 760, height: 780)
        case (.quick, .sideBySide): CGSize(width: 720, height: 430)
        case (.quick, .stacked): CGSize(width: 540, height: 620)
        }
    }

    func minimumSize(for window: TranslationWindowKind) -> CGSize {
        switch (window, self) {
        case (.main, .sideBySide): CGSize(width: 660, height: 440)
        case (.main, .stacked): CGSize(width: 660, height: 640)
        case (.quick, .sideBySide): CGSize(width: 600, height: 340)
        case (.quick, .stacked): CGSize(width: 460, height: 480)
        }
    }
}

enum TranslationWindowKind: String, CaseIterable, Sendable {
    case main, quick
}

/// Stores preferences only. Language support and successful hot-key registration
/// remain responsibilities of the catalog and the app's settings coordinator.
@MainActor @Observable
final class AppPreferences {
    private(set) var defaultTarget: String
    private(set) var sourceLanguageIdentifiers: [String]?
    private(set) var targetLanguageIdentifiers: [String]?
    private(set) var recentSourceLanguages: [String]
    private(set) var recentTargetLanguages: [String]
    static let recentLanguageLimit = 5
    var interfaceLanguage: AppInterfaceLanguage {
        didSet {
            guard interfaceLanguage != oldValue else { return }
            defaults.set(interfaceLanguage.rawValue, forKey: StorageKey.interfaceLanguage)
        }
    }
    var interfaceLocale: Locale {
        Locale(identifier: interfaceLanguage.resolvedLanguageIdentifier())
    }
    var appearance: AppAppearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: StorageKey.appearance)
        }
    }
    var material: AppMaterial {
        didSet {
            guard material != oldValue else { return }
            defaults.set(material.rawValue, forKey: StorageKey.material)
        }
    }
    var hoverCursor: HoverCursor {
        didSet {
            guard hoverCursor != oldValue else { return }
            defaults.set(hoverCursor.rawValue, forKey: StorageKey.hoverCursor)
        }
    }
    var translationLayout: TranslationLayout {
        didSet {
            guard translationLayout != oldValue else { return }
            defaults.set(translationLayout.rawValue, forKey: StorageKey.translationLayout)
        }
    }
    var usesPointingCursor: Bool {
        get { hoverCursor == .pointingHand }
        set { hoverCursor = newValue ? .pointingHand : .arrow }
    }
    private(set) var shortcutRevision: UInt64 = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var storedShortcuts: [ShortcutAction: StoredShortcut] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let sourceRange = Self.savedLanguageRange(defaults.object(forKey: StorageKey.sourceLanguages))
        let targetRange = Self.savedLanguageRange(defaults.object(forKey: StorageKey.targetLanguages))
        sourceLanguageIdentifiers = sourceRange
        targetLanguageIdentifiers = targetRange
        recentSourceLanguages = Array(Self.normalizedLanguages(defaults.stringArray(forKey: StorageKey.recentSourceLanguages) ?? [])
            .filter { sourceRange?.contains($0) ?? true }.prefix(Self.recentLanguageLimit))
        recentTargetLanguages = Array(Self.normalizedLanguages(defaults.stringArray(forKey: StorageKey.recentTargetLanguages) ?? [])
            .filter { targetRange?.contains($0) ?? true }.prefix(Self.recentLanguageLimit))
        let savedTarget = Self.normalizedTarget(defaults.object(forKey: StorageKey.defaultTarget) as? String) ?? "zh-Hans"
        defaultTarget = targetRange.map { $0.contains(savedTarget) ? savedTarget : $0[0] } ?? savedTarget
        interfaceLanguage = (defaults.object(forKey: StorageKey.interfaceLanguage) as? String)
            .flatMap(AppInterfaceLanguage.init(rawValue:)) ?? .system
        appearance = (defaults.object(forKey: StorageKey.appearance) as? String)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        material = (defaults.object(forKey: StorageKey.material) as? String)
            .flatMap(AppMaterial.init(rawValue:)) ?? .light
        hoverCursor = (defaults.object(forKey: StorageKey.hoverCursor) as? String)
            .flatMap(HoverCursor.init(rawValue:)) ?? .pointingHand
        translationLayout = (defaults.object(forKey: StorageKey.translationLayout) as? String)
            .flatMap(TranslationLayout.init(rawValue:)) ?? .sideBySide
        for action in ShortcutAction.allCases {
            guard let data = defaults.data(forKey: StorageKey.shortcut(action)),
                  let stored = try? JSONDecoder().decode(StoredShortcut.self, from: data),
                  stored.isValid else { continue }
            storedShortcuts[action] = stored
        }
    }

    /// Logical points only: display scaling must never compound on restoration.
    /// Permission/OCR placeholder sizes are not recorded as reading preferences.
    func windowSize(for window: TranslationWindowKind, layout: TranslationLayout) -> CGSize? {
        guard let data = defaults.data(forKey: StorageKey.windowSize(window, layout)),
              let saved = try? JSONDecoder().decode(SavedWindowSize.self, from: data), saved.isValid else { return nil }
        return CGSize(width: saved.width, height: saved.height)
    }

    func rememberWindowSize(_ size: CGSize, for window: TranslationWindowKind, layout: TranslationLayout) {
        let saved = SavedWindowSize(width: size.width, height: size.height)
        guard saved.isValid, let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: StorageKey.windowSize(window, layout))
    }

    private struct SavedWindowSize: Codable {
        let width: Double
        let height: Double
        var isValid: Bool {
            width.isFinite && height.isFinite && (320...16384).contains(width) && (240...16384).contains(height)
        }
    }

    func setDefaultTarget(_ identifier: String) {
        guard let target = Self.normalizedTarget(identifier), target != defaultTarget,
              isLanguageEnabled(target, for: .target) else { return }
        defaults.set(target, forKey: StorageKey.defaultTarget)
        defaultTarget = target
    }

    func enabledLanguageIdentifiers(for side: TranslationSide) -> [String]? {
        side == .source ? sourceLanguageIdentifiers : targetLanguageIdentifiers
    }

    func recentLanguages(for side: TranslationSide) -> [String] {
        side == .source ? recentSourceLanguages : recentTargetLanguages
    }

    func isLanguageEnabled(_ identifier: String, for side: TranslationSide) -> Bool {
        if identifier == "auto" { return side == .source }
        return enabledLanguageIdentifiers(for: side)?.contains(LanguageCatalog.canonicalIdentifier(identifier)) ?? true
    }

    func filterLanguages(_ languages: [TranslationLanguage], for side: TranslationSide) -> [TranslationLanguage] {
        languages.filter { isLanguageEnabled($0.id, for: side) }
    }

    /// Nil follows the full service catalogue, including languages added later.
    /// A custom range always contains at least two distinct concrete languages.
    @discardableResult func setEnabledLanguages(_ identifiers: [String]?, for side: TranslationSide) -> Bool {
        let normalized = identifiers.map(Self.normalizedLanguages)
        guard normalized == nil || normalized!.count >= 2 else { return false }
        guard normalized != enabledLanguageIdentifiers(for: side) else { return true }
        let key = side == .source ? StorageKey.sourceLanguages : StorageKey.targetLanguages
        if let normalized { defaults.set(normalized, forKey: key) }
        else { defaults.removeObject(forKey: key) }
        if side == .source { sourceLanguageIdentifiers = normalized }
        else { targetLanguageIdentifiers = normalized }
        storeRecentLanguages(recentLanguages(for: side).filter { isLanguageEnabled($0, for: side) }, for: side)
        if side == .target, !isLanguageEnabled(defaultTarget, for: .target), let first = normalized?.first {
            setDefaultTarget(first)
        }
        return true
    }

    /// Only explicit menu choices call this. Detection, swaps and restored work
    /// must not change either side's recency or store any translation content.
    func recordLanguageChoice(_ identifier: String, for side: TranslationSide) {
        guard let identifier = Self.normalizedTarget(identifier), isLanguageEnabled(identifier, for: side) else { return }
        let recent = [identifier] + recentLanguages(for: side).filter { $0 != identifier }
        storeRecentLanguages(Array(recent.prefix(Self.recentLanguageLimit)), for: side)
    }

    private func storeRecentLanguages(_ identifiers: [String], for side: TranslationSide) {
        guard identifiers != recentLanguages(for: side) else { return }
        defaults.set(identifiers, forKey: side == .source ? StorageKey.recentSourceLanguages : StorageKey.recentTargetLanguages)
        if side == .source { recentSourceLanguages = identifiers }
        else { recentTargetLanguages = identifiers }
    }

    private static func normalizedLanguages(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap(normalizedTarget).filter { seen.insert($0).inserted }
    }

    private static func savedLanguageRange(_ value: Any?) -> [String]? {
        guard let values = value as? [String] else { return nil }
        let normalized = normalizedLanguages(values)
        return normalized.count >= 2 ? normalized : nil
    }

    func shortcut(for action: ShortcutAction) -> GlobalShortcut? {
        // Reading through this method participates in SwiftUI Observation even
        // though the encoded overrides themselves are an implementation detail.
        _ = shortcutRevision
        switch storedShortcuts[action] {
        case .disabled, .paused: return nil
        case .enabled(let shortcut): return shortcut
        case nil: return action.defaultShortcut
        }
    }

    /// Keeps the chosen combination visible while disabled. Legacy disabled
    /// records did not retain a key; offer the current default without enabling it.
    func rememberedShortcut(for action: ShortcutAction) -> GlobalShortcut {
        _ = shortcutRevision
        switch storedShortcuts[action] {
        case .enabled(let shortcut), .paused(let shortcut): return shortcut
        case .disabled, nil: return action.defaultShortcut
        }
    }

    /// Call only after the coordinator successfully registers or removes the
    /// system shortcut; persistence itself does not register or validate conflicts.
    func setShortcut(_ shortcut: GlobalShortcut?, for action: ShortcutAction) {
        guard shortcut?.isValid != false else { return }
        let stored = shortcut.map(StoredShortcut.enabled) ?? .paused(rememberedShortcut(for: action))
        store(stored, for: action)
    }

    func setPausedShortcut(_ shortcut: GlobalShortcut, for action: ShortcutAction) {
        guard shortcut.isValid else { return }
        store(.paused(shortcut), for: action)
    }

    private func store(_ stored: StoredShortcut, for action: ShortcutAction) {
        guard storedShortcuts[action] != stored,
              let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: StorageKey.shortcut(action))
        storedShortcuts[action] = stored
        shortcutRevision &+= 1
    }

    enum StorageKey {
        static let sourceLanguages = "preferences.sourceLanguages"
        static let targetLanguages = "preferences.targetLanguages"
        static let recentSourceLanguages = "preferences.recentSourceLanguages"
        static let recentTargetLanguages = "preferences.recentTargetLanguages"
        static let defaultTarget = "preferences.defaultTarget"
        static let interfaceLanguage = "preferences.interfaceLanguage"
        static let appearance = "preferences.appearance"
        static let material = "preferences.material"
        static let hoverCursor = "preferences.hoverCursor"
        static let translationLayout = "preferences.translationLayout"
        static func windowSize(_ window: TranslationWindowKind, _ layout: TranslationLayout) -> String {
            "preferences.windowSize.\(window.rawValue).\(layout.rawValue)"
        }

        static func shortcut(_ action: ShortcutAction) -> String {
            "preferences.shortcut.\(action.rawValue)"
        }
    }

    private enum StoredShortcut: Codable, Equatable {
        case disabled
        case enabled(GlobalShortcut)
        case paused(GlobalShortcut)

        var isValid: Bool {
            switch self {
            case .disabled: true
            case .enabled(let shortcut), .paused(let shortcut): shortcut.isValid
            }
        }
    }

    private static func normalizedTarget(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard trimmed.lowercased() != "auto", isLanguageIdentifier(trimmed) else { return nil }
        let canonical = LanguageCatalog.canonicalIdentifier(trimmed)
        guard !canonical.isEmpty, canonical.lowercased() != "auto", isLanguageIdentifier(canonical) else { return nil }
        return canonical
    }

    /// Check the language-tag syntax before Foundation's permissive parser can
    /// turn malformed input into a different language. This does not assert that
    /// Apple Translation supports an otherwise well-formed language identifier.
    private static func isLanguageIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.lowercased().split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...8).contains(language.count), letters(language) else { return false }
        var index = 1
        if language.count <= 3 {
            var extlangs = 0
            while index < parts.count, parts[index].count == 3, letters(parts[index]), extlangs < 3 {
                index += 1
                extlangs += 1
            }
        }
        if index < parts.count, parts[index].count == 4, letters(parts[index]) { index += 1 }
        if index < parts.count,
           (parts[index].count == 2 && letters(parts[index])) || (parts[index].count == 3 && digits(parts[index])) {
            index += 1
        }
        var variants: Set<Substring> = []
        while index < parts.count {
            let part = parts[index]
            let isVariant = (5...8).contains(part.count) && alphanumeric(part)
                || part.count == 4 && part.first?.isASCII == true && part.first?.isNumber == true && alphanumeric(part)
            guard isVariant else { break }
            guard variants.insert(part).inserted else { return false }
            index += 1
        }
        var extensions: Set<Substring> = []
        while index < parts.count, parts[index].count == 1, parts[index] != "x", alphanumeric(parts[index]) {
            guard extensions.insert(parts[index]).inserted else { return false }
            index += 1
            let start = index
            while index < parts.count, (2...8).contains(parts[index].count), alphanumeric(parts[index]) { index += 1 }
            guard index > start else { return false }
        }
        if index < parts.count, parts[index] == "x" {
            index += 1
            let start = index
            while index < parts.count, (1...8).contains(parts[index].count), alphanumeric(parts[index]) { index += 1 }
            guard index > start else { return false }
        }
        return index == parts.count
    }

    private static func letters(_ part: Substring) -> Bool {
        !part.isEmpty && part.utf8.allSatisfy { (97...122).contains($0) }
    }

    private static func digits(_ part: Substring) -> Bool {
        !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func alphanumeric(_ part: Substring) -> Bool {
        !part.isEmpty && part.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }
}
