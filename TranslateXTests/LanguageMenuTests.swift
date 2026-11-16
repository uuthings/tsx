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
        func menus(_ view: NSView) -> [LanguageMenuControl] {
            if let menu = view as? LanguageMenuControl { return [menu] }
            return view.subviews.flatMap(menus)
        }
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

    func testRecentGroupPreservesRecencyWithoutDuplicatesAndSeparatesOnlyNonemptyGroups() {
        let control = makeControl()
        control.selection = "fr"
        control.usesLanguageGroups = true
        control.recentLanguageIdentifiers = ["fr", "fr", "missing"]
        let menu = control.selectionMenu()
        XCTAssertEqual(selectableItems(menu).compactMap { $0.representedObject as? String }, ["fr", "en"])
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), [L10n.string("Recent languages"), L10n.string("Other languages")])
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
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), [L10n.string("Recent languages")])
    }

    func testFirstUseHasOnlyAllLanguagesAndExcludedCurrentSelectionIsNotReinserted() {
        let control = makeControl()
        control.usesLanguageGroups = true
        control.selection = "ja"
        control.preservesUnavailableSelection = false
        let menu = control.selectionMenu()
        XCTAssertEqual(selectableItems(menu).compactMap { $0.representedObject as? String }, ["en", "fr"])
        XCTAssertFalse(menu.items.contains(where: \.isSeparatorItem))
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), [L10n.string("All languages")])
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
