import Foundation

struct FTPSSettings: Codable {
    var host: String = ""
    var port: Int = 21
    var username: String = ""
    var password: String = ""
    var remotePath: String = "/"
    var useImplicitTLS: Bool = false
    var passiveMode: Bool = true
    var trustSelfSignedCertificates: Bool = true

    private static let userDefaultsKey = "ftps_notes_settings_v1"

    static func load() -> FTPSSettings {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(FTPSSettings.self, from: data) else {
            return FTPSSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: FTPSSettings.userDefaultsKey)
        }
    }

    var isConfigured: Bool { !host.isEmpty && !username.isEmpty }
}
