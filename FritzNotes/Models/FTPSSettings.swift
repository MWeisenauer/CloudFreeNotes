import Foundation

nonisolated struct FTPSSettings: Codable, Sendable {
    var host: String = ""
    var port: Int = 21
    var username: String = ""
    var password: String = ""
    var remotePath: String = "/"
    var useImplicitTLS: Bool = false
    var passiveMode: Bool = true
    var trustSelfSignedCertificates: Bool = true

    private static let userDefaultsKey = "ftps_notes_settings_v1"
    private static let keychainAccount = "ftps_notes_password_v1"

    static func load() -> FTPSSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              var settings = try? JSONDecoder().decode(FTPSSettings.self, from: data) else {
            return FTPSSettings()
        }
        if let stored = KeychainStore.string(for: keychainAccount) {
            settings.password = stored
        } else if !settings.password.isEmpty {
            // Migration: a previous version stored the password in UserDefaults.
            // Move it into the Keychain and strip it from the plaintext store.
            settings.save()
        }
        return settings
    }

    func save() {
        KeychainStore.setString(password, for: FTPSSettings.keychainAccount)
        // Persist everything except the password as plaintext JSON.
        var sanitized = self
        sanitized.password = ""
        if let data = try? JSONEncoder().encode(sanitized) {
            UserDefaults.standard.set(data, forKey: FTPSSettings.userDefaultsKey)
        }
    }

    var isConfigured: Bool { !host.isEmpty && !username.isEmpty }
}
