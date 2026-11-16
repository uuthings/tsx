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
            Text("Choose the languages shown in the source and target menus.")
                .font(.system(size: 11)).foregroundStyle(p.muted)
            VStack(spacing: 0) {
                row(.source)
                Rectangle().fill(p.line).frame(height: 1).accessibilityHidden(true)
                row(.target)
            }
            .background(p.panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(p.line) }
            Text("The 5 most recently selected languages appear first. Source and target histories are separate.")
                .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
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
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(L10n.string(side == .source ? "Source language" : "Target language"))
                    .font(.system(size: 13, weight: .medium))
                Text(String(format: L10n.string("%d languages"), count)).font(.system(size: 11)).foregroundStyle(p.muted)
                Spacer()
                Button("Choose languages…") { editingSide = side }
                    .buttonStyle(TranslationServiceButtonStyle())
                    .accessibilityIdentifier("settings.languages.\(side == .source ? "source" : "target").edit")
            }
            Text(summary(selected)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(L10n.string(side == .source
                ? "Automatic detection is always available and does not count toward the language minimum."
                : "Keep at least 2 languages."))
                .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(14)
    }

    private func summary(_ identifiers: [String]?) -> String {
        guard let identifiers else { return L10n.string("All languages") }
        let names = identifiers.prefix(5).map { LanguageCatalog.displayName(for: $0) }.joined(separator: L10n.string("language.listSeparator"))
        return identifiers.count > 5 ? String(format: L10n.string("%@ and %d more"), names, identifiers.count - 5) : names
    }
}

struct TranslationLanguageSelection: View {
    @Bindable var preferences: AppPreferences
    let catalog: LanguageCatalog
    let side: TranslationSide
    let done: () -> Void
    @Environment(\.translateXTheme) private var theme
    @State private var search = ""
    @State private var draft: [String]?
    private var p: TranslationServicePalette { .init(theme: theme) }

    init(preferences: AppPreferences, catalog: LanguageCatalog, side: TranslationSide, done: @escaping () -> Void) {
        self.preferences = preferences
        self.catalog = catalog
        self.side = side
        self.done = done
        _draft = State(initialValue: preferences.enabledLanguageIdentifiers(for: side))
    }
    private var languages: [TranslationLanguage] {
        let catalog = catalog.preferenceLanguages(for: side)
        let missing = (preferences.enabledLanguageIdentifiers(for: side) ?? []).filter { id in !catalog.contains { $0.id == id } }
        return catalog + missing.map { .init(id: $0, name: LanguageCatalog.displayName(for: $0)) }
    }
    var body: some View {
        let languages = languages
        let enabled = draft ?? languages.map(\.id)
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleLanguages = query.isEmpty ? languages : languages.filter { $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.string(side == .source ? "Choose source languages" : "Choose target languages"))
                    .font(.system(size: 16, weight: .medium))
                Spacer()
                Text(String(format: L10n.string("%d selected"), enabled.count)).font(.system(size: 12)).foregroundStyle(p.muted)
            }
            Text("Available choices also depend on the selected translation service.")
                .font(.system(size: 12)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            TextField("Find a language", text: $search)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("settings.languages.search")
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(visibleLanguages) { language in
                        Toggle(language.name, isOn: Binding(
                            get: { draft?.contains(language.id) ?? true },
                            set: { selected in
                                let enabled = draft ?? languages.map(\.id)
                                let updated = selected ? enabled + [language.id] : enabled.filter { $0 != language.id }
                                draft = updated
                            }
                        ))
                        .toggleStyle(.checkbox).font(.system(size: 13))
                        .frame(minHeight: 30, alignment: .leading)
                        .accessibilityIdentifier("settings.languages.\(side == .source ? "source" : "target").\(language.id)")
                    }
                }.padding(.vertical, 2).translateXScrollContent()
                if visibleLanguages.isEmpty {
                    Text("No matching languages").font(.system(size: 12)).foregroundStyle(p.muted).padding(.vertical, 16)
                }
            }.frame(height: 280)
            Text(L10n.string(enabled.count < 2
                ? "Select at least 2 languages to save."
                : "Keep at least 2 languages."))
                .font(.system(size: 11)).foregroundStyle(p.muted).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(p.line).frame(height: 1).accessibilityHidden(true)
            HStack {
                Button("Use all languages") { draft = nil }
                    .buttonStyle(TranslationServiceButtonStyle(kind: .quiet))
                    .disabled(draft == nil)
                Button("Clear selection") { draft = [] }
                    .buttonStyle(TranslationServiceButtonStyle(kind: .quiet))
                    .disabled(enabled.isEmpty)
                Spacer()
                Button("Done") {
                    if preferences.setEnabledLanguages(draft, for: side) { done() }
                }.buttonStyle(TranslationServiceButtonStyle(kind: .primary, minimumWidth: 70))
                    .disabled(enabled.count < 2)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 460).foregroundStyle(p.ink).background(p.panel)
    }
}
