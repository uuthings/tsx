import AppKit
import SwiftUI
import XCTest
@testable import TranslateX

@MainActor
final class LanguageMenuTests: XCTestCase {
    func testHostedMenusSharePersistentPreferencesAndRefreshAfterRangeChanges() async throws {
        let suite = "TranslateXTests.HostedLanguageMenus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let model = TranslationModel(languagePreferences: preferences)
        let languages = [TranslationLanguage(id: "en", name: "English"), .init(id: "fr", name: "French"), .init(id: "de", name: "German")]
        let host = NSHostingView(rootView: TranslateXThemeHost(preferences: preferences) {
            HStack {
                LanguageMenu(label: "Source language", selection: Binding(get: { model.source }, set: { model.source = $0 }),
                             languages: languages, includeAuto: true, preferenceSide: .source)
                LanguageMenu(label: "Target language", selection: Binding(get: { model.target }, set: { model.target = $0 }),
                             languages: languages, preferenceSide: .target)
            }
        })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.close() }
        panel.orderFront(nil)
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if menus(host).count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let source = try XCTUnwrap(menus(host).first { $0.accessibilityLabel() == "Source language" })
        let target = try XCTUnwrap(menus(host).first { $0.accessibilityLabel() == "Target language" })
        try invoke(item("fr", in: source.selectionMenu()))
        try invoke(item("de", in: target.selectionMenu()))
        XCTAssertEqual(preferences.recentSourceLanguages, ["fr"])
        XCTAssertEqual(preferences.recentTargetLanguages, ["de"])
        preferences.setEnabledLanguages(["en", "de"], for: .source)
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if source.languages.map(\.id) == ["en", "de"], model.source == "auto" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(source.languages.map(\.id), ["en", "de"])
        XCTAssertEqual(model.source, "auto")
        XCTAssertEqual(selectableItems(source.selectionMenu()).compactMap { $0.representedObject as? String }, ["auto", "en", "de"])
        XCTAssertEqual(target.languages, languages)
        XCTAssertEqual(target.recentLanguageIdentifiers, ["de"])
        XCTAssertTrue(preferences.recentSourceLanguages.isEmpty)
    }

    func testMainWindowKeepsConfiguredLanguagesAcrossSelectionsAndServiceChanges() async throws {
        let windows = try isolatedWindows()
        defer { windows.shutdown() }
        let preferences = windows.preferences
        let model = windows.inputModel
        let catalog = windows.languages
        await catalog.load()
        let host = NSHostingView(rootView: TranslateXThemeHost(preferences: preferences) {
            TranslationWorkspace(model: model, catalog: catalog)
        })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        defer { panel.close() }
        panel.orderBack(nil)
        func settle(until ready: () -> Bool) async throws {
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                if ready() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Main window menus did not refresh")
        }
        try await settle { self.menus(host).count == 2 }
        let source = try XCTUnwrap(menus(host).first { $0.includeAuto })
        let target = try XCTUnwrap(menus(host).first { !$0.includeAuto })
        let six = ["is", "fa", "ru", "zh-Hans", "he", "hu"]

        func assertRows(_ control: LanguageMenuControl, ids: [String], supported: Set<String>,
                        file: StaticString = #filePath, line: UInt = #line) throws {
            let menu = try XCTUnwrap(control.menu, file: file, line: line)
            menu.update()
            let rows = selectableItems(menu)
            let expected = control.includeAuto ? ["auto"] + ids : ids
            XCTAssertEqual(rows.compactMap { $0.representedObject as? String }.sorted(), expected.sorted(), file: file, line: line)
            for row in rows {
                let id = try XCTUnwrap(row.representedObject as? String)
                let available = id == "auto" || supported.contains(id)
                XCTAssertEqual(row.isEnabled, available, id, file: file, line: line)
                if !available {
                    XCTAssertEqual(row.title, String(format: L10n.string("%@ (unsupported by this service)"),
                                                      LanguageCatalog.displayName(for: id)), file: file, line: line)
                    XCTAssertNotNil(row.toolTip, file: file, line: line)
                }
            }
        }

        let apple = Set(catalog.languages.map(\.id))
        for (side, control) in [(TranslationSide.source, source), (.target, target)] {
            XCTAssertNil(preferences.enabledLanguageIdentifiers(for: side))
            try assertRows(control, ids: catalog.preferenceLanguages(for: side).map(\.id), supported: apple)
            XCTAssertTrue(preferences.setEnabledLanguages(six, for: side))
        }
        model.target = "is"
        try await settle { source.languages.count == 6 && target.languages.count == 6 && target.selection == "is" }
        for control in [source, target] { try assertRows(control, ids: six, supported: apple) }
        if apple.contains("ru") {
            try invoke(item("ru", in: XCTUnwrap(target.menu)))
            try await settle { target.selection == "ru" }
            try assertRows(target, ids: six, supported: apple)
        }

        let limited = TranslationServiceConfiguration(kind: .deepL)
        let broader = TranslationServiceConfiguration(kind: .deepSeek)
        try windows.services.save(limited, apiKey: "fixture-key")
        try windows.services.save(broader, apiKey: "fixture-key")
        model.selectService(limited.id)
        let supported = Set(catalog.languages(for: limited).map(\.id))
        try await settle { target.supportedIdentifiers == supported }
        for control in [source, target] {
            try assertRows(control, ids: six, supported: supported)
            let disabled = try item("is", in: XCTUnwrap(control.menu))
            XCTAssertFalse(disabled.isEnabled)
            try invoke(disabled)
            try invoke(item(control === source ? "he" : "hu", in: XCTUnwrap(control.menu)))
        }
        try await settle { source.selection == "he" && target.selection == "hu" }
        for control in [source, target] { try assertRows(control, ids: six, supported: supported) }
        XCTAssertEqual(preferences.recentSourceLanguages, ["he"])
        XCTAssertEqual(preferences.recentTargetLanguages, apple.contains("ru") ? ["hu", "ru"] : ["hu"])

        model.selectService(broader.id)
        try await settle { target.supportedIdentifiers?.contains("is") == true && source.supportedIdentifiers?.contains("is") == true }
        for control in [source, target] { try assertRows(control, ids: six, supported: Set(six)) }
        try invoke(item("is", in: XCTUnwrap(target.menu)))
        XCTAssertEqual(model.target, "is")
        XCTAssertEqual(preferences.recentTargetLanguages.first, "is")
        XCTAssertEqual(preferences.recentSourceLanguages, ["he"])

        let regional = ["de", "de-CH", "fr", "fr-CA"]
        for side in [TranslationSide.source, .target] {
            XCTAssertTrue(preferences.setEnabledLanguages(regional, for: side))
        }
        let openAI = TranslationServiceConfiguration(kind: .openAI)
        try windows.services.save(openAI, apiKey: "fixture-key")
        for service in [openAI, broader] {
            model.selectService(service.id)
            XCTAssertEqual(model.serviceConfiguration?.id, service.id)
            try await settle { source.languages.count == 4 && target.languages.count == 4 }
            for control in [source, target] { try assertRows(control, ids: regional, supported: Set(regional)) }
            try invoke(item("de-CH", in: XCTUnwrap(source.menu)))
            try invoke(item("fr-CA", in: XCTUnwrap(target.menu)))
            XCTAssertEqual(model.source, "de-CH")
            XCTAssertEqual(model.target, "fr-CA")
        }
    }

    func testRecentGroupPreservesRecencyWithoutDuplicatesAndSeparatesOnlyNonemptyGroups() {
        let control = makeControl()
        control.selection = "fr"
        control.includeAuto = true
        control.usesLanguageGroups = true
        control.recentLanguageIdentifiers = ["fr", "fr", "missing"]
        let menu = control.selectionMenu()
        XCTAssertEqual(selectableItems(menu).compactMap { $0.representedObject as? String }, ["auto", "fr", "en"])
        XCTAssertEqual(menu.items.firstIndex(where: \.isSeparatorItem), 2, "Auto and recent choices are contiguous")
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
        XCTAssertFalse(menu.items.contains(where: \.isSectionHeader))
        XCTAssertEqual(selectableItems(menu).filter { $0.state == .on }.map(\.title), ["Français — catalog label"])
    }

    func testRecentOnlyMenuHasNoSeparatorEvenWithAutomaticDetection() {
        let control = makeControl()
        control.usesLanguageGroups = true
        control.includeAuto = true
        control.recentLanguageIdentifiers = ["fr", "en"]
        let menu = control.selectionMenu()
        XCTAssertEqual(selectableItems(menu).compactMap { $0.representedObject as? String }, ["auto", "fr", "en"])
        XCTAssertFalse(menu.items.contains(where: \.isSeparatorItem))
        XCTAssertFalse(menu.items.contains(where: \.isSectionHeader))
    }

    func testFirstUseHasOnlyAllLanguagesAndExcludedCurrentSelectionIsNotReinserted() {
        let control = makeControl()
        control.usesLanguageGroups = true
        control.selection = "ja"
        control.preservesUnavailableSelection = false
        let menu = control.selectionMenu()
        XCTAssertEqual(selectableItems(menu).compactMap { $0.representedObject as? String }, ["en", "fr"])
        XCTAssertFalse(menu.items.contains(where: \.isSeparatorItem))
        XCTAssertFalse(menu.items.contains(where: \.isSectionHeader))
        control.languages = []
        let empty = control.selectionMenu()
        XCTAssertTrue(selectableItems(empty).isEmpty)
        XCTAssertFalse(empty.items.contains(where: \.isSeparatorItem))
        XCTAssertEqual(empty.items.last?.title, L10n.string("No enabled languages for this service"))
        XCTAssertEqual(empty.items.last?.isEnabled, false)
    }

    func testAutomaticAndManualSelectionsHaveExactlyOneCheckmark() async throws {
        let control = makeControl()
        control.includeAuto = true
        for selection in ["auto", "fr", "en"] {
            control.selection = selection
            let menu = control.selectionMenu()
            let choices = selectableItems(menu)
            XCTAssertEqual(choices.compactMap { $0.representedObject as? String }, ["auto", "en", "fr"])
            XCTAssertFalse(menu.items.contains(where: \.isSeparatorItem), "Auto remains in the language list when there are no recent choices")
            XCTAssertEqual(choices.filter { $0.state == .on }.compactMap { $0.representedObject as? String }, [selection])
            XCTAssertTrue(choices.filter { ($0.representedObject as? String) != selection }.allSatisfy { $0.state == .off })
        }
    }

    func testManualMenuIncludesOnlyCatalogLanguagesAndNoAutomaticChoice() async throws {
        let control = makeControl()
        control.includeAuto = false
        control.selection = "en"
        let choices = selectableItems(control.selectionMenu())
        XCTAssertEqual(choices.compactMap { $0.representedObject as? String }, ["en", "fr"])
        XCTAssertEqual(choices.map(\.title), control.languages.map(\.name),
                       "Catalog-provided names and ordering should be preserved")
        XCTAssertEqual(choices.filter { $0.state == .on }.count, 1)
    }

    func testUnavailableCurrentLanguageIsKeptWithoutInventingOtherChoices() async throws {
        let control = makeControl()
        control.selection = "qaa"
        control.includeAuto = true
        var choices = selectableItems(control.selectionMenu())
        XCTAssertEqual(choices.compactMap { $0.representedObject as? String }, ["auto", "qaa", "en", "fr"])
        XCTAssertEqual(choices.filter { $0.state == .on }.compactMap { $0.representedObject as? String }, ["qaa"])

        control.languages = []
        control.includeAuto = false
        choices = selectableItems(control.selectionMenu())
        XCTAssertEqual(choices.compactMap { $0.representedObject as? String }, ["qaa"],
                       "An empty capability catalog must not populate guessed supported languages")
        XCTAssertEqual(choices.first?.state, .on)
    }

    func testNativeMenuActionDeliversTheIdentifierRatherThanItsDisplayName() async throws {
        let control = makeControl()
        control.includeAuto = true
        control.selection = "en"
        var selected = "en"
        var callbacks: [String] = []
        control.onSelect = { identifier in
            selected = identifier
            callbacks.append(identifier)
        }
        let menu = control.selectionMenu()
        let french = try item("fr", in: menu)
        XCTAssertEqual(french.title, "Français — catalog label")
        try invoke(french)
        XCTAssertEqual(selected, "fr")
        XCTAssertEqual(callbacks, ["fr"])

        try invoke(try item("auto", in: menu))
        XCTAssertEqual(selected, "auto")
        XCTAssertEqual(callbacks, ["fr", "auto"])
    }

    func testDisablingAfterMenuCreationRejectsItsPreviouslyEnabledAction() async throws {
        let control = makeControl()
        control.selection = "en"
        var selected = "en"
        var callbackCount = 0
        control.onSelect = { identifier in
            selected = identifier
            callbackCount += 1
        }
        let oldMenu = control.selectionMenu()
        let french = try item("fr", in: oldMenu)
        control.isEnabled = false
        try invoke(french)
        XCTAssertEqual(selected, "en")
        XCTAssertEqual(control.selection, "en")
        XCTAssertEqual(callbackCount, 0, "A stale menu action cannot bypass the control's current disabled state")

        control.isEnabled = true
        try invoke(french)
        XCTAssertEqual(selected, "fr")
        XCTAssertEqual(callbackCount, 1)
    }

    func testRefreshUpdatesSpokenSelectionWithoutLosingTheControlLabel() async throws {
        let control = makeControl()
        control.setAccessibilityLabel("Source language")
        for identifier in ["auto", "fr", "qaa"] {
            control.selection = identifier
            control.refreshTitle()
            let expected = control.languages.first(where: { $0.id == identifier })?.name ?? (identifier == "auto" ? L10n.string("Detect language") : LanguageCatalog.displayName(for: identifier))
            XCTAssertEqual(control.accessibilityValue() as? String, expected)
            XCTAssertEqual(control.accessibilityLabel(), "Source language")
            XCTAssertEqual(control.accessibilityRole(), .popUpButton)
        }
    }

    func testDisplayedPullDownKeepsItsValueAndAllChoicesAfterNativeSelection() async throws {
        let control = makeControl()
        control.includeAuto = true
        control.selection = "en"
        control.onSelect = { identifier in
            control.selection = identifier
            control.refreshTitle()
        }
        control.refreshTitle()
        XCTAssertTrue(control.pullsDown, "A dropdown must attach to the button edge, not cover its value")
        XCTAssertTrue(control.usesItemFromMenu)
        XCTAssertNil(control.menu?.items.first?.representedObject, "Only a dedicated display item may be hidden")
        XCTAssertEqual(control.menu?.items.first?.isHidden, true)
        XCTAssertEqual(control.preferredEdge, control.isFlipped ? .maxY : .minY)

        for identifier in ["fr", "auto", "en"] {
            let menu = try XCTUnwrap(control.menu)
            let selected = try item(identifier, in: menu)
            menu.performActionForItem(at: menu.index(of: selected))
            XCTAssertEqual(control.selection, identifier)
            let displayName = control.languages.first(where: { $0.id == identifier })?.name ?? (identifier == "auto" ? L10n.string("Detect language") : LanguageCatalog.displayName(for: identifier))
            XCTAssertTrue(control.attributedTitle.string.hasPrefix(displayName))
            XCTAssertEqual(control.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, control.labelFont)
            XCTAssertEqual(control.accessibilityValue() as? String, displayName)
            let updated = selectableItems(try XCTUnwrap(control.menu))
            XCTAssertTrue(updated.allSatisfy { !$0.isHidden }, "Native pull-downs must not hide the first real choice")
            XCTAssertEqual(control.menu?.font, NSFont.systemFont(ofSize: 13))
            XCTAssertEqual(updated.compactMap { $0.representedObject as? String }, ["auto", "en", "fr"])
            XCTAssertEqual(updated.filter { $0.state == .on }.compactMap { $0.representedObject as? String }, [identifier])
        }
    }

    func testDisplayedMenuRefreshesWhenAvailableLanguagesChange() async throws {
        let control = makeControl()
        control.selection = "fr"
        control.refreshTitle()
        control.languages = [TranslationLanguage(id: "en", name: "English — updated catalog label")]
        control.refreshTitle()
        let choices = selectableItems(try XCTUnwrap(control.menu))
        XCTAssertTrue(choices.allSatisfy { !$0.isHidden })
        XCTAssertEqual(choices.compactMap { $0.representedObject as? String }, ["fr", "en"])
        XCTAssertEqual(choices.last?.title, "English — updated catalog label")
        XCTAssertEqual(choices.first?.state, .on)
        XCTAssertEqual(control.accessibilityValue() as? String, LanguageCatalog.displayName(for: "fr"))
    }

    func testLongMenuConfinementKeepsScrollingBelowTheButton() {
        let screen = NSRect(x: 0, y: 24, width: 1440, height: 876)
        let anchor = NSRect(x: 1300, y: 550, width: 130, height: 30)
        let bounds = LanguageMenuControl.menuConfinementRect(anchor: anchor, visibleFrame: screen)
        XCTAssertTrue(screen.contains(bounds))
        XCTAssertEqual(bounds.maxY, anchor.minY - 4)
        XCTAssertEqual(bounds.minY, screen.minY)
        XCTAssertEqual(bounds.width, screen.width, "AppKit can shift a wide menu away from the right edge")
        XCTAssertFalse(bounds.intersects(anchor))
    }

    func testNearBottomMenuConfinementUsesSpaceAboveOnOffsetDisplay() {
        let screen = NSRect(x: -1280, y: -900, width: 1280, height: 876)
        let anchor = NSRect(x: -220, y: -840, width: 130, height: 30)
        let bounds = LanguageMenuControl.menuConfinementRect(anchor: anchor, visibleFrame: screen)
        XCTAssertTrue(screen.contains(bounds))
        XCTAssertEqual(bounds.minY, anchor.maxY + 4)
        XCTAssertEqual(bounds.maxY, screen.maxY)
        XCTAssertFalse(bounds.intersects(anchor))
    }

    private func menus(_ view: NSView) -> [LanguageMenuControl] {
        if let menu = view as? LanguageMenuControl { return [menu] }
        return view.subviews.flatMap(menus)
    }

    private func makeControl() -> LanguageMenuControl {
        _ = NSApplication.shared
        let control = LanguageMenuControl()
        control.labelFont = .systemFont(ofSize: 14, weight: .semibold)
        control.languages = [
            TranslationLanguage(id: "en", name: "English — catalog label"),
            TranslationLanguage(id: "fr", name: "Français — catalog label")
        ]
        return control
    }

    private func selectableItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.representedObject is String }
    }

    private func item(_ identifier: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { ($0.representedObject as? String) == identifier })
    }

    private func invoke(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action)
        let target = try XCTUnwrap(item.target)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: item), "Use the same AppKit target-action route as the native menu")
    }
}
