import AppKit
import SwiftUI

struct TranslationLanguageSettings: View {
    @Bindable var preferences: AppPreferences
    let catalog: LanguageCatalog
    @Environment(\.translateXTheme) private var theme
    @State private var editingSide: TranslationSide?
    private var p: TranslationServicePalette { .init(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Translation languages").font(.system(size: 11, weight: .medium)).foregroundStyle(p.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose the languages shown in the source and target menus.")
                Text("The 5 most recently selected languages appear first. Source and target histories are separate.")
            }
            .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                row(.source)
                Rectangle().fill(p.line).frame(height: 1).accessibilityHidden(true)
                row(.target)
            }
            .padding(.horizontal, 17)
            .background(p.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(p.line) }
        }
        .sheet(isPresented: Binding(get: { editingSide != nil }, set: { if !$0 { editingSide = nil } })) {
            if let editingSide {
                TranslationLanguageSelection(preferences: preferences, catalog: catalog, side: editingSide) {
                    self.editingSide = nil
                }
            }
        }
        .serviceDesignMetric("settings.translationLanguages")
    }

    private func row(_ side: TranslationSide) -> some View {
        let selected = preferences.enabledLanguageIdentifiers(for: side)
        let count = selected?.count ?? catalog.preferenceLanguages(for: side).count
        return HStack(spacing: 8) {
            Text(L10n.string(side == .source ? "Source language" : "Target language"))
                .font(.system(size: 13, weight: .medium))
            Text(String(format: L10n.string("%d languages"), count)).font(.system(size: 11)).foregroundStyle(p.muted)
            Spacer()
            Button("Select") { editingSide = side }
                .buttonStyle(TranslationServiceButtonStyle())
                .accessibilityIdentifier("settings.languages.\(side == .source ? "source" : "target").edit")
        }.frame(minHeight: 52)
    }
}

struct TranslationLanguageSelection: View {
    @Bindable var preferences: AppPreferences
    let catalog: LanguageCatalog
    let side: TranslationSide
    let done: () -> Void
    @Environment(\.translateXTheme) private var theme
    @State private var search = ""
    @State private var draft: TranslationLanguageSelectionDraft
    private var p: TranslationServicePalette { .init(theme: theme) }

    init(preferences: AppPreferences, catalog: LanguageCatalog, side: TranslationSide, done: @escaping () -> Void) {
        self.preferences = preferences
        self.catalog = catalog
        self.side = side
        self.done = done
        _draft = State(initialValue: TranslationLanguageSelectionDraft(identifiers: preferences.enabledLanguageIdentifiers(for: side)))
    }
    private var languages: [TranslationLanguage] {
        let catalog = catalog.preferenceLanguages(for: side)
        let missing = (preferences.enabledLanguageIdentifiers(for: side) ?? []).filter { id in !catalog.contains { $0.id == id } }
        return catalog + missing.map { .init(id: $0, name: LanguageCatalog.displayName(for: $0)) }
    }
    var body: some View {
        let languages = languages
        let identifiers = languages.map(\.id)
        let enabled = draft.enabled(in: identifiers)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleLanguages = query.isEmpty ? languages : languages.filter { $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(L10n.string(side == .source ? "Source language" : "Target language"))
                    .font(.system(size: 16, weight: .medium))
                Text(String(format: L10n.string("%d selected"), enabled.count)).font(.system(size: 12)).foregroundStyle(p.muted)
                Spacer()
                Button(action: done) { Image(systemName: "xmark") }
                    .buttonStyle(TranslationServiceIconButtonStyle())
                    .accessibilityLabel(L10n.string("Cancel"))
            }
            HStack(spacing: 14) {
                LanguageSelectionCheckbox(title: L10n.string(query.isEmpty ? "Select all" : "Select results"),
                    state: draft.state(visible: visibleLanguages.map(\.id), catalog: identifiers), enabled: !visibleLanguages.isEmpty) {
                    draft.toggleAll(visible: visibleLanguages.map(\.id), catalog: identifiers)
                }.fixedSize().translateXControlCursor()
                TranslationServiceField(title: "Find a language", text: $search, placeholder: "Find a language", leadingSymbol: "magnifyingglass")
                    .accessibilityIdentifier("settings.languages.search")
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(visibleLanguages) { language in
                        Toggle(language.name, isOn: Binding(
                            get: { draft.enabled(in: identifiers).contains(language.id) },
                            set: { selected in
                                draft.set(language.id, selected: selected, catalog: identifiers)
                            }
                        ))
                        .toggleStyle(.checkbox).font(.system(size: 13))
                        .frame(minHeight: 30, alignment: .leading)
                        .accessibilityIdentifier("settings.languages.\(side == .source ? "source" : "target").\(language.id)")
                    }
                }.padding(.trailing, 12).padding(.vertical, 2).translateXScrollContent(alignsVerticalKnob: true)
                if visibleLanguages.isEmpty {
                    Text("No matching languages").font(.system(size: 12)).foregroundStyle(p.muted).padding(.vertical, 16)
                }
            }.id(query).frame(height: 252).scrollIndicators(.automatic, axes: .vertical)
                .padding(.trailing, -TranslateXScrollStyle.verticalKnobTrailingInset)
            HStack {
                Text(L10n.string(enabled.count < 2 ? "Select at least 2 languages to save." : "Keep at least 2 languages."))
                    .font(.system(size: 11)).foregroundStyle(enabled.count < 2 ? p.error : p.muted)
                Spacer()
                Button("Done") {
                    if preferences.setEnabledLanguages(draft.identifiers, for: side) { done() }
                }.buttonStyle(TranslationServiceButtonStyle(kind: .primary, minimumWidth: 70))
                    .disabled(enabled.count < 2)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 460).foregroundStyle(p.ink).background(p.panel)
        .onExitCommand(perform: done)
    }
}

/// A nil range follows the entire catalog, including languages added later.
struct TranslationLanguageSelectionDraft {
    var identifiers: [String]?
    func enabled(in catalog: [String]) -> [String] { identifiers ?? catalog }
    func state(visible: [String], catalog: [String]) -> NSControl.StateValue {
        let selected = Set(enabled(in: catalog)).intersection(visible).count
        return selected == 0 ? .off : selected == visible.count ? .on : .mixed
    }
    mutating func toggleAll(visible: [String], catalog: [String]) {
        guard !visible.isEmpty else { return }
        var selected = Set(enabled(in: catalog))
        if state(visible: visible, catalog: catalog) == .on { selected.subtract(visible) }
        else { selected.formUnion(visible) }
        update(selected, catalog: catalog)
    }
    mutating func set(_ identifier: String, selected: Bool, catalog: [String]) {
        var values = Set(enabled(in: catalog))
        if selected { values.insert(identifier) } else { values.remove(identifier) }
        update(values, catalog: catalog)
    }
    private mutating func update(_ values: Set<String>, catalog: [String]) {
        identifiers = values == Set(catalog) ? nil : catalog.filter(values.contains)
    }
}

/// AppKit supplies the same checkbox appearance and mixed-state accessibility
/// as the individual language toggles. Partial selection always selects all.
struct LanguageSelectionCheckbox: NSViewRepresentable {
    let title: String
    let state: NSControl.StateValue
    let enabled: Bool
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: context.coordinator, action: #selector(Coordinator.toggle))
        button.allowsMixedState = true
        button.font = .systemFont(ofSize: 12)
        button.setAccessibilityIdentifier("settings.languages.all")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title; button.state = state; button.isEnabled = enabled
        context.coordinator.action = action
    }
    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func toggle() { action?() }
    }
}
