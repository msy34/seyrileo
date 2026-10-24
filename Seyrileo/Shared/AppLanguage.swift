import Foundation
import Observation
import ObjectiveC
import SwiftUI

/// The languages Seyrileo ships. Names are always shown in their own language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, tr, fr, ar, ru, de, bs

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .en: "🇬🇧"
        case .tr: "🇹🇷"
        case .fr: "🇫🇷"
        case .ar: "🇸🇦"
        case .ru: "🇷🇺"
        case .de: "🇩🇪"
        case .bs: "🇧🇦"
        }
    }

    var nativeName: String {
        switch self {
        case .en: "English"
        case .tr: "Türkçe"
        case .fr: "Français"
        case .ar: "العربية"
        case .ru: "Русский"
        case .de: "Deutsch"
        case .bs: "Bosanski"
        }
    }

    var isRightToLeft: Bool { self == .ar }
    var locale: Locale { Locale(identifier: rawValue) }
}

/// The app's language. English unless the user picks another one in Seyrileo (the device
/// language is deliberately not used — owner decision). The choice applies at once: lookups in
/// the main bundle are answered from the chosen `.lproj`, and the root view is rebuilt.
/// It is also written to `AppleLanguages` so system-provided text matches on the next launch.
@MainActor
@Observable
final class LanguageSettings {
    private(set) var current: AppLanguage
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private static let key = "appLanguage"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        current = defaults.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .en
        apply()
    }

    func select(_ language: AppLanguage) {
        guard language != current else { return }
        current = language
        apply()
    }

    private func apply() {
        Locale.appLanguageCode = current.rawValue
        defaults.set(current.rawValue, forKey: Self.key)
        defaults.set([current.rawValue], forKey: "AppleLanguages")
        LocalizedMainBundle.use(current.rawValue)
    }
}

/// Answers `Bundle.main` string lookups from the chosen language's `.lproj`. Installed once by
/// changing the class of `Bundle.main` to this subclass (Objective-C runtime, no private API).
private nonisolated final class LocalizedMainBundle: Bundle, @unchecked Sendable {
    nonisolated(unsafe) private static var languageBundle: Bundle?
    nonisolated(unsafe) private static var languageCode: String?
    nonisolated(unsafe) static var languageBundleURL: URL?
    nonisolated(unsafe) private static var installed = false

    @MainActor
    static func use(_ code: String) {
        if !installed {
            object_setClass(Bundle.main, LocalizedMainBundle.self)
            installed = true
        }
        languageBundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
        languageCode = code
        languageBundleURL = languageBundle?.bundleURL
    }

    /// Used by `String(localized:)` (it passes the system's languages); answer in ours.
    override func __localizedString(forKey key: String, value: String?, table tableName: String?, localizations: [String]) -> String {
        localizedString(forKey: key, value: value, table: tableName)
    }

    override var preferredLocalizations: [String] {
        Self.languageCode.map { [$0] } ?? super.preferredLocalizations
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let bundle = Self.languageBundle {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Locale {
    nonisolated(unsafe) fileprivate(set) static var appLanguageCode = AppLanguage.en.rawValue
    /// The app's chosen language (formatting of numbers and dates in localized strings).
    static var app: Locale { Locale(identifier: appLanguageCode) }
}

extension String {
    /// A localized string in the app's chosen language. Use instead of `String(localized:)`,
    /// which keeps the language the process started with. Literals passed here are still
    /// extracted into the string catalog (the parameter is a `LocalizedStringResource`).
    init(app resource: LocalizedStringResource) {
        var resource = resource
        resource.locale = .app
        // `bundle` is read-only; its Codable form carries the bundle URL, so point that at the
        // chosen language's .lproj. Foundation then formats arguments (and plurals) as usual.
        if let url = LocalizedMainBundle.languageBundleURL,
           var json = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(resource))) as? [String: Any] {
            json["bundleURL"] = url.absoluteString
            json.removeValue(forKey: "sandboxExtensionToken")
            if let data = try? JSONSerialization.data(withJSONObject: json),
               let moved = try? JSONDecoder().decode(LocalizedStringResource.self, from: data) {
                resource = moved
            }
        }
        self.init(localized: resource)
    }
}

extension Text {
    /// `Text` for a `LocalizedStringResource` (e.g. `UserIssue` texts) in the chosen language.
    init(app resource: LocalizedStringResource) {
        self.init(verbatim: String(app: resource))
    }
}

// MARK: - Picker

struct LanguageRow: View {
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: language.flag)
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(verbatim: language.nativeName)
                .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
        }
    }
}

struct LanguagePickerView: View {
    @Environment(LanguageSettings.self) private var languages
    @Environment(\.dismiss) private var dismiss
    var closesOnSelect = false

    var body: some View {
        BrandList {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    languages.select(language)
                    if closesOnSelect { dismiss() }
                } label: {
                    HStack {
                        LanguageRow(language: language)
                        Spacer()
                        if language == languages.current {
                            Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(language == languages.current ? .isSelected : [])
            }
        }
        .navigationTitle("Language")
    }
}

/// Settings row: current flag and language, opens the picker.
struct LanguageSettingsSection: View {
    @Environment(LanguageSettings.self) private var languages

    var body: some View {
        Section {
            NavigationLink {
                LanguagePickerView()
            } label: {
                LabeledContent {
                    Text(verbatim: "\(languages.current.flag) \(languages.current.nativeName)")
                } label: {
                    Label("Language", systemImage: "globe")
                }
            }
        }
    }
}

/// Small flag button for screens without Settings (the welcome screen).
struct LanguageMenuButton: View {
    @Environment(LanguageSettings.self) private var languages
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: languages.current.flag)
                Text(verbatim: languages.current.rawValue.uppercased())
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.12), in: Capsule())
            .foregroundStyle(.white)
        }
        .accessibilityLabel(Text("Language"))
        .sheet(isPresented: $showing) {
            NavigationStack {
                LanguagePickerView(closesOnSelect: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { showing = false } }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
