import SwiftUI

struct SettingsView: View {
    @State private var settings = FTPSSettings.load()
    @State private var isTesting = false
    @State private var testReport: ConnectionReport?
    @State private var testError: String?
    @State private var showSaveConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("FTPS-Server") {
                    TextField("Host (z.B. 192.168.1.1)", text: $settings.host)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", value: $settings.port, format: .number)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(width: 80)
                    }
                    Toggle("Implizites TLS (ftps://, Port 990)", isOn: $settings.useImplicitTLS)
                        .onChange(of: settings.useImplicitTLS) { _, enabled in
                            settings.port = enabled ? 990 : 21
                        }
                }
                Section("Zugangsdaten") {
                    TextField("Benutzername", text: $settings.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passwort", text: $settings.password)
                        .textContentType(.password)
                }
                Section("Verzeichnis auf dem Server") {
                    TextField("Pfad (z.B. /notizen/)", text: $settings.remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Verbindungsoptionen") {
                    Toggle("Passiver Modus (PASV)", isOn: $settings.passiveMode)
                    Toggle("Selbstsignierten Zertifikaten vertrauen", isOn: $settings.trustSelfSignedCertificates)
                }
                Section {
                    Button("Einstellungen speichern") {
                        settings.save()
                        showSaveConfirmation = true
                    }
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)

                }
                Section {
                    NavigationLink {
                        EncryptionSetupView()
                    } label: {
                        HStack {
                            Label("Inhaltsverschlüsselung", systemImage: verschluesselungSymbol)
                            Spacer()
                            Text(verschluesselungZustand)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Verschlüsselung")
                } footer: {
                    Text("FTPS schützt die Leitung. Die Inhaltsverschlüsselung schützt zusätzlich die Dateien selbst – auf dem Server liegen sie dann unlesbar.")
                }
                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Spacer()
                            if isTesting { ProgressView().padding(.trailing, 6) }
                            Text(isTesting ? "Verbinde…" : "Verbindung testen")
                            Spacer()
                        }
                    }
                    .disabled(isTesting || !settings.isConfigured)
                }
                if let error = testError {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.callout)
                        }
                    }
                }
                if let report = testReport {
                    Section("Ergebnis") {
                        statusRow(
                            ok: true,
                            title: "Verbunden",
                            detail: "\(report.noteCount) Notiz(en) im Verzeichnis"
                        )
                        statusRow(
                            ok: report.controlEncrypted,
                            title: "Steuerkanal",
                            detail: report.controlEncrypted
                                ? "verschlüsselt (AUTH TLS)"
                                : "unverschlüsselt"
                        )
                        // Der wichtigste Punkt: hier laufen die Notizinhalte.
                        statusRow(
                            ok: report.dataEncrypted,
                            title: "Datenkanal",
                            detail: report.dataEncrypted
                                ? "verschlüsselt (PROT P)"
                                : "KLARTEXT – die Notizinhalte gehen offen über die Leitung"
                        )
                        statusRow(
                            ok: true,
                            title: "Betriebsart",
                            detail: report.passiveCommand == "EPSV"
                                ? "EPSV (auch über IPv6)"
                                : "PASV (nur IPv4)"
                        )
                        statusRow(
                            ok: report.certificateChecked,
                            title: "Zertifikat",
                            detail: report.certificateChecked
                                ? "geprüft"
                                : "nicht geprüft – schützt vor Mitlesen, nicht vor einem untergeschobenen Server"
                        )
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .alert("Gespeichert", isPresented: $showSaveConfirmation) {
                Button("OK") {}
            } message: {
                Text("Die FTPS-Einstellungen wurden gespeichert.")
            }
        }
    }

    private var verschluesselungZustand: String {
        if EncryptionPolicy.mayEncrypt { return "Aktiv" }
        if CryptoKeyStore.hasMasterKey { return "Eingerichtet" }
        return "Aus"
    }

    private var verschluesselungSymbol: String {
        EncryptionPolicy.mayEncrypt ? "lock.fill" : "lock.open"
    }

    // Ein Punkt gilt nur dann als in Ordnung, wenn er wirklich schützt – ein
    // grüner Haken über einem Klartext-Datenkanal wäre irreführend.
    @ViewBuilder
    private func statusRow(ok: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func testConnection() async {
        settings.save()
        isTesting = true
        testReport = nil
        testError = nil
        do {
            testReport = try await NoteService(settings: settings).testConnection()
        } catch {
            testError = error.localizedDescription
        }
        isTesting = false
    }
}
