import Combine
import Foundation

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var preferences: GuardPreferences {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private let storageKey = "TrackpadGuard.preferences.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(GuardPreferences.self, from: data) {
            preferences = decoded
        } else {
            preferences = GuardPreferences()
        }
    }

    public func resetActivationRegion() {
        preferences.activationRegion = .default
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
