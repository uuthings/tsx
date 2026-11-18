import XCTest
@testable import TranslateX

@MainActor
final class LanguagePreferencesTests: XCTestCase {
    func testBulkCheckboxSelectsPartialScopeAndKeepsHiddenChoices() {
        let catalog = ["en", "fr", "de", "ja"]
        var draft = TranslationLanguageSelectionDraft(identifiers: ["en", "ja"])
        XCTAssertEqual(draft.state(visible: ["en", "fr"], catalog: catalog), .mixed)
        draft.toggleAll(visible: ["en", "fr"], catalog: catalog)
        XCTAssertEqual(draft.enabled(in: catalog), ["en", "fr", "ja"])
        XCTAssertEqual(draft.state(visible: ["en", "fr"], catalog: catalog), .on)
        draft.toggleAll(visible: ["en", "fr"], catalog: catalog)
        XCTAssertEqual(draft.enabled(in: catalog), ["ja"])
        XCTAssertEqual(draft.state(visible: ["en", "fr"], catalog: catalog), .off)
        draft.toggleAll(visible: [], catalog: catalog)
        XCTAssertEqual(draft.enabled(in: catalog), ["ja"])
    }

    func testBulkSelectionRestoresDynamicCatalogAndDoesNotSaveInvalidDraft() throws {
        try withPreferences { preferences, _ in
            let catalog = ["en", "fr", "ja"]
            var draft = TranslationLanguageSelectionDraft(identifiers: ["en"])
            draft.toggleAll(visible: catalog, catalog: catalog)
            XCTAssertNil(draft.identifiers)
            XCTAssertEqual(draft.enabled(in: catalog + ["de"]), catalog + ["de"])
            draft.toggleAll(visible: catalog, catalog: catalog)
            XCTAssertEqual(draft.identifiers, [])
            XCTAssertFalse(preferences.setEnabledLanguages(draft.identifiers, for: .source))
            draft.set("fr", selected: true, catalog: catalog)
            XCTAssertFalse(preferences.setEnabledLanguages(draft.identifiers, for: .source))
            draft.set("ja", selected: true, catalog: catalog)
            XCTAssertTrue(preferences.setEnabledLanguages(draft.identifiers, for: .source))
            XCTAssertEqual(preferences.sourceLanguageIdentifiers, ["fr", "ja"])
            XCTAssertNil(preferences.targetLanguageIdentifiers)
        }
    }

    func testRecentChoicesAreDistinctLimitedToFiveAndPersistSeparately() throws {
        try withPreferences { preferences, defaults in
            for id in ["en", "fr", "de", "it", "es", "ja", "fr", "en-US"] {
                preferences.recordLanguageChoice(id, for: .source)
            }
            preferences.recordLanguageChoice("zh", for: .target)
            preferences.recordLanguageChoice("ja", for: .target)
            preferences.recordLanguageChoice("auto", for: .source)
            preferences.recordLanguageChoice("not a language", for: .target)
            XCTAssertEqual(preferences.recentLanguages(for: .source), ["en", "fr", "ja", "es", "it"])
            XCTAssertEqual(preferences.recentLanguages(for: .target), ["ja", "zh-Hans"])
            let restored = AppPreferences(defaults: defaults)
            XCTAssertEqual(restored.recentSourceLanguages, preferences.recentSourceLanguages)
            XCTAssertEqual(restored.recentTargetLanguages, preferences.recentTargetLanguages)
        }
    }

    func testRangesNormalizeAliasesRejectFewerThanTwoAndRemainIndependent() throws {
        try withPreferences { preferences, defaults in
            XCTAssertNil(preferences.sourceLanguageIdentifiers)
            XCTAssertNil(preferences.targetLanguageIdentifiers)
            XCTAssertFalse(preferences.setEnabledLanguages(["auto", "en-US", "en"], for: .source))
            XCTAssertTrue(preferences.setEnabledLanguages(["zh", "en-US", "en"], for: .source))
            XCTAssertEqual(preferences.sourceLanguageIdentifiers, ["zh-Hans", "en"])
            XCTAssertNil(preferences.targetLanguageIdentifiers)
            XCTAssertTrue(preferences.isLanguageEnabled("auto", for: .source))
            XCTAssertFalse(preferences.isLanguageEnabled("auto", for: .target))
            let restored = AppPreferences(defaults: defaults)
            XCTAssertEqual(restored.sourceLanguageIdentifiers, ["zh-Hans", "en"])
            XCTAssertNil(restored.targetLanguageIdentifiers)
            XCTAssertFalse(restored.setEnabledLanguages([], for: .source))
            XCTAssertEqual(restored.sourceLanguageIdentifiers, ["zh-Hans", "en"])
        }
    }

    func testRemovingLanguagePrunesHistoryAndRepairsDefaultWithoutCreatingRecency() throws {
        try withPreferences { preferences, defaults in
            for id in ["zh-Hans", "en", "ja"] { preferences.recordLanguageChoice(id, for: .target) }
            preferences.recordLanguageChoice("zh-Hans", for: .source)
            XCTAssertTrue(preferences.setEnabledLanguages(["en", "ja"], for: .target))
            XCTAssertEqual(preferences.defaultTarget, "en")
            XCTAssertEqual(preferences.recentTargetLanguages, ["ja", "en"])
            XCTAssertEqual(preferences.recentSourceLanguages, ["zh-Hans"])
            preferences.recordLanguageChoice("zh-Hans", for: .target)
            preferences.setDefaultTarget("zh-Hans")
            XCTAssertEqual(preferences.recentTargetLanguages, ["ja", "en"])
            XCTAssertEqual(preferences.defaultTarget, "en")
            XCTAssertEqual(AppPreferences(defaults: defaults).defaultTarget, "en")
            XCTAssertTrue(preferences.setEnabledLanguages(nil, for: .target))
            XCTAssertNil(defaults.object(forKey: AppPreferences.StorageKey.targetLanguages))
            XCTAssertEqual(preferences.recentTargetLanguages, ["ja", "en"])
        }
    }

    func testCorruptStoredRangesAndHistoriesRecoverWithoutChangingOtherPreferences() throws {
        try withPreferences { _, defaults in
            defaults.set(["auto", "en", "en-US"], forKey: AppPreferences.StorageKey.sourceLanguages)
            defaults.set(["fr", "de"], forKey: AppPreferences.StorageKey.targetLanguages)
            defaults.set(["auto", "en-US", "en", "invalid id", "ja", "fr", "de", "es", "it"], forKey: AppPreferences.StorageKey.recentSourceLanguages)
            defaults.set(["en", "de", "fr"], forKey: AppPreferences.StorageKey.recentTargetLanguages)
            defaults.set("preserve", forKey: "unrelated")
            let restored = AppPreferences(defaults: defaults)
            XCTAssertNil(restored.sourceLanguageIdentifiers)
            XCTAssertEqual(restored.targetLanguageIdentifiers, ["fr", "de"])
            XCTAssertEqual(restored.defaultTarget, "fr")
            XCTAssertEqual(restored.recentSourceLanguages, ["en", "ja", "fr", "de", "es"])
            XCTAssertEqual(restored.recentTargetLanguages, ["de", "fr"])
            XCTAssertEqual(defaults.string(forKey: "unrelated"), "preserve")
        }
    }

    func testConfiguredLanguagesIncludeSavedEntriesMissingFromTheCatalog() throws {
        try withPreferences { preferences, _ in
            preferences.setEnabledLanguages(["en", "ja"], for: .source)
            let catalog = [TranslationLanguage(id: "fr", name: "French"), .init(id: "en", name: "English")]
            XCTAssertEqual(preferences.configuredLanguages(in: catalog, for: .source).map(\.id), ["en", "ja"])
            XCTAssertEqual(preferences.configuredLanguages(in: catalog, for: .target), catalog)
            XCTAssertEqual(preferences.languageOptions(in: catalog, for: .source).map(\.id), ["fr", "en", "ja"])
        }
    }

    func testPreferenceChangeCancelsOldRequestWithoutSendingExistingText() async throws {
        let (preferences, defaults, suite) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TranslationModel(automaticallyTranslates: true, languagePreferences: preferences)
        model.source = "en"
        model.text = "A constructed sentence for language preferences."
        model.submit()
        XCTAssertNotNil(model.request)
        preferences.setEnabledLanguages(["fr", "ja"], for: .source)
        preferences.setEnabledLanguages(["de", "ja"], for: .target)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.source, "auto")
        XCTAssertEqual(model.target, "de")
        XCTAssertNil(model.request)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.text, "A constructed sentence for language preferences.")
        XCTAssertTrue(preferences.recentSourceLanguages.isEmpty)
        XCTAssertTrue(preferences.recentTargetLanguages.isEmpty)
    }

    func testRangeChangeThatRetainsCurrentChoicesDoesNotCancelRequest() async throws {
        let (preferences, defaults, suite) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TranslationModel(languagePreferences: preferences)
        model.source = "en"
        model.text = "A constructed request."
        model.submit()
        let request = try XCTUnwrap(model.request)
        preferences.setEnabledLanguages(["en", "ja"], for: .source)
        preferences.setEnabledLanguages(["zh-Hans", "ja"], for: .target)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(model.request, request)
    }

    func testSwapAndHandoffDoNotReintroduceExcludedChoicesOrRecordRecentLanguages() throws {
        try withPreferences { preferences, _ in
            let model = TranslationModel(languagePreferences: preferences)
            model.source = "en"
            model.text = "A constructed handoff."
            let handoff = try XCTUnwrap(model.makeHandoff())
            model.swapLanguages()
            XCTAssertTrue(preferences.recentSourceLanguages.isEmpty)
            XCTAssertTrue(preferences.recentTargetLanguages.isEmpty)
            preferences.setEnabledLanguages(["fr", "ja"], for: .source)
            preferences.setEnabledLanguages(["de", "it"], for: .target)
            model.acceptHandoff(handoff)
            XCTAssertEqual(model.source, "auto")
            XCTAssertEqual(model.target, "de")
            XCTAssertEqual(model.text, handoff.text)
            XCTAssertNil(model.request)
            XCTAssertNil(model.result)
            XCTAssertFalse(model.canSwapLanguages)
        }
    }

    private func makePreferences() throws -> (AppPreferences, UserDefaults, String) {
        let suite = "TranslateXTests.LanguagePreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (AppPreferences(defaults: defaults), defaults, suite)
    }

    private func withPreferences(_ body: (AppPreferences, UserDefaults) throws -> Void) throws {
        let (preferences, defaults, suite) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(preferences, defaults)
    }
}
