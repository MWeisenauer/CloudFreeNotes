import Foundation

// MARK: - Error types

enum FTPSError: LocalizedError {
    case notConfigured
    case connectionFailed(String)
    case authFailed
    case tlsFailed
    case listingFailed
    case downloadFailed
    case uploadFailed(String)
    case deleteFailed(String)
    case invalidResponse(String)
    case notConnected
    case dataChannelFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:             return "FTPS nicht konfiguriert – bitte Einstellungen prüfen."
        case .connectionFailed(let msg): return "Verbindungsfehler: \(msg)"
        case .authFailed:                return "Anmeldung fehlgeschlagen – Benutzername oder Passwort prüfen."
        case .tlsFailed:                 return "TLS/SSL-Handshake fehlgeschlagen."
        case .listingFailed:             return "Verzeichnisliste konnte nicht geladen werden."
        case .downloadFailed:            return "Datei konnte nicht heruntergeladen werden."
        case .uploadFailed(let msg):     return "Upload fehlgeschlagen: \(msg)"
        case .deleteFailed(let msg):     return "Löschen fehlgeschlagen: \(msg)"
        case .invalidResponse(let msg):  return "Ungültige Server-Antwort: \(msg)"
        case .notConnected:              return "Nicht mit FTP-Server verbunden."
        case .dataChannelFailed(let msg): return "Datenkanal: \(msg)"
        }
    }
}

// MARK: - TLS delegate

// Gilt nur noch fuer die Steuerverbindung: der Datenkanal laeuft ueber
// NWConnection und kennt diesen Delegate nicht – siehe FTPSDataChannel.
final class FTPSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let allowSelfSigned: Bool

    init(allowSelfSigned: Bool) {
        self.allowSelfSigned = allowSelfSigned
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if allowSelfSigned {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Bericht von "Verbindung testen"

// Beschreibt, was auf der Leitung tatsaechlich passiert ist. Wichtig ist die
// Trennung: `controlEncrypted` sagt nichts ueber die Dateiinhalte aus, die
// laufen ueber den Datenkanal. Beides getrennt auszuweisen ist der Zweck
// dieses Typs – ein gruener Haken allein hat den offenen Datenkanal monatelang
// verdeckt.
nonisolated struct ConnectionReport: Sendable {
    var noteCount: Int
    var controlEncrypted: Bool      // AUTH TLS auf der Steuerverbindung
    var dataEncrypted: Bool         // PROT P auf dem Datenkanal
    var passiveCommand: String      // "EPSV" (IPv6-faehig) oder "PASV"
    var certificateChecked: Bool    // false, wenn selbstsignierten Zertifikaten vertraut wird

    /// Der Test gilt nur als bestanden, wenn auch die Inhalte geschuetzt sind.
    var isFullyEncrypted: Bool { controlEncrypted && dataEncrypted }
}

// MARK: - Note service

// Uses explicit TLS (AUTH TLS) for the control connection and a passive data
// channel requested with EPSV (IPv6-capable) or PASV.
//
// Der Datenkanal ist verschluesselt (PROT P) und laeuft ueber FTPSDataChannel.
// Nur wenn ein Server das Kommando PROT P selbst zurueckweist, faellt die
// Verbindung auf Klartext zurueck. Scheitert spaeter der Handschlag, wird der
// Fehler gemeldet und NICHT still auf Klartext umgeschaltet.
actor NoteService {
    private let settings: FTPSSettings

    private var controlTask: URLSessionStreamTask?
    private var urlSession: URLSession?
    private var ftpDelegate: FTPSDelegate?
    private var readBuffer = Data()
    private var encryptDataChannel = true   // PROT P; nur auf Serverwunsch abgeschaltet
    private var supportsEPSV: Bool?         // nil = not probed yet, set on first data channel

    // An IPv6 literal may be entered with or without brackets; the stream API wants it bare.
    private var normalizedHost: String {
        var host = settings.host.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    // A bare IPv6 literal is the only host form containing a colon.
    private var hostIsIPv6Literal: Bool { normalizedHost.contains(":") }

    private let commandTimeout: TimeInterval = 30
    private let readTimeout: TimeInterval    = 30
    private let dataTimeout: TimeInterval    = 120

    init(settings: FTPSSettings) {
        self.settings = settings
    }

    // MARK: - Public API

    func fetchAllNotes() async throws -> [Note] {
        guard settings.isConfigured else { throw FTPSError.notConfigured }
        try await connect()
        defer { disconnect() }
        let filenames = try await listFiles()
        var notes: [Note] = []
        for filename in filenames {
            if let note = try? await fetchNote(filename: filename) {
                notes.append(note)
            }
        }
        return notes.sorted { $0.modifiedDate > $1.modifiedDate }
    }

    func uploadNote(_ note: Note) async throws {
        guard settings.isConfigured else { throw FTPSError.notConfigured }
        guard let data = encode(note).data(using: .utf8) else {
            throw FTPSError.uploadFailed("Notiz konnte nicht kodiert werden.")
        }
        try await connect()
        defer { disconnect() }
        try await storeFile(filename: note.remoteFilename, data: data)
    }

    func deleteNote(filename: String) async throws {
        guard settings.isConfigured else { throw FTPSError.notConfigured }
        try await connect()
        defer { disconnect() }
        guard let controlTask else { throw FTPSError.notConnected }
        try await send("DELE \(filename)\r\n", to: controlTask)
        let resp = try await readResponse(from: controlTask)
        guard resp.hasPrefix("2") else {
            throw FTPSError.deleteFailed(resp)
        }
    }

    func testConnection() async throws -> ConnectionReport {
        guard settings.isConfigured else { throw FTPSError.notConfigured }
        try await connect()
        defer { disconnect() }
        // Erst nach listFiles() berichten: dabei ist tatsaechlich etwas durch den
        // Datenkanal gelaufen. Die blosse Antwort auf PROT P waere ein
        // Versprechen, keine Messung.
        let filenames = try await listFiles()
        return ConnectionReport(
            noteCount: filenames.count,
            controlEncrypted: true,   // ohne 234 auf AUTH TLS kaeme connect() nicht bis hierher
            dataEncrypted: encryptDataChannel,
            passiveCommand: supportsEPSV == true ? "EPSV" : "PASV",
            certificateChecked: !settings.trustSelfSignedCertificates
        )
    }

    // MARK: - Note encoding / decoding
    // Format: line 1 = title, line 2 = ISO8601 date, lines 3+ = body

    private func encode(_ note: Note) -> String {
        let dateStr = ISO8601DateFormatter().string(from: note.modifiedDate)
        return note.title + "\n" + dateStr + "\n" + note.body
    }

    private func decode(_ text: String, filename: String) -> Note {
        var note = Note()
        note.remoteFilename = filename
        let uuidStr = filename.hasSuffix(".txt") ? String(filename.dropLast(4)) : filename
        note.id = UUID(uuidString: uuidStr) ?? UUID()
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 1 { note.title = lines[0] }
        if lines.count >= 2 { note.modifiedDate = ISO8601DateFormatter().date(from: lines[1]) ?? Date() }
        if lines.count >= 3 { note.body = lines[2...].joined(separator: "\n") }
        return note
    }

    // MARK: - Connection lifecycle

    private func connect() async throws {
        let delegate = FTPSDelegate(allowSelfSigned: settings.trustSelfSignedCertificates)
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest  = commandTimeout
        sessionConfig.timeoutIntervalForResource = dataTimeout
        let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        ftpDelegate = delegate
        urlSession  = session
        readBuffer  = Data()
        supportsEPSV = nil

        let task = session.streamTask(withHostName: normalizedHost, port: settings.port)
        task.resume()

        let banner = try await readResponse(from: task)
        guard banner.hasPrefix("220") else {
            throw FTPSError.connectionFailed("Kein FTP-Banner: \(banner)")
        }

        try await send("AUTH TLS\r\n", to: task)
        let authResp = try await readResponse(from: task)
        guard authResp.hasPrefix("234") else { throw FTPSError.tlsFailed }
        task.startSecureConnection()

        try await send("USER \(settings.username)\r\n", to: task)
        let userResp = try await readResponse(from: task)
        if userResp.hasPrefix("331") {
            try await send("PASS \(settings.password)\r\n", to: task)
            let passResp = try await readResponse(from: task)
            guard passResp.hasPrefix("230") else { throw FTPSError.authFailed }
        } else if !userResp.hasPrefix("230") {
            throw FTPSError.authFailed
        }

        try await send("PBSZ 0\r\n", to: task)
        _ = try await readResponse(from: task)
        // PROT P: verschluesselter Datenkanal – die Dateiinhalte gingen vorher
        // offen ueber die Leitung.
        //
        // Der alte Kommentar hier lastete das der Fritz!Box an ("antwortet 200,
        // verschluesselt aber nicht"). Das ist widerlegt: die Ursache lagen im
        // Client – ein fehlender Verify-Block und die falsche Reihenfolge,
        // Einzelheiten in FTPSDataChannel.
        //
        // Zurueckgefallen wird nur, wenn der Server das Kommando selbst
        // zurueckweist. Genau das stille Zurueckfallen bei einem spaeteren
        // Fehler hat dafuer gesorgt, dass die Inhalte lange offen uebertragen
        // wurden, ohne dass es auffiel.
        try await send("PROT P\r\n", to: task)
        let protResp = try await readResponse(from: task)
        if protResp.hasPrefix("2") {
            encryptDataChannel = true
        } else {
            encryptDataChannel = false
            try await send("PROT C\r\n", to: task)
            _ = try await readResponse(from: task)
        }

        let path = settings.remotePath.isEmpty ? "/" : settings.remotePath
        if path != "/" {
            try await send("CWD \(path)\r\n", to: task)
            let cwdResp = try await readResponse(from: task)
            guard cwdResp.hasPrefix("2") else {
                throw FTPSError.connectionFailed("Verzeichnis nicht gefunden: \(path)")
            }
        }

        controlTask = task
    }

    private func disconnect() {
        controlTask?.cancel()
        controlTask = nil
        urlSession?.invalidateAndCancel()
        urlSession  = nil
        ftpDelegate = nil
    }

    // MARK: - FTP operations

    private func listFiles() async throws -> [String] {
        guard let controlTask else { throw FTPSError.notConnected }
        try await send("TYPE A\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)

        let dataChannel = try await openDataChannel(controlTask: controlTask)
        try await send("NLST\r\n", to: controlTask)
        let reply = try await readResponse(from: controlTask)

        if reply.hasPrefix("226") || reply.hasPrefix("250") {
            dataChannel.cancel()
            return []
        }
        guard reply.hasPrefix("125") || reply.hasPrefix("150") else {
            dataChannel.cancel()
            throw FTPSError.connectionFailed("NLST fehlgeschlagen: \(reply)")
        }

        // Jetzt hat vsftpd den Handschlag begonnen.
        try await dataChannel.awaitReady()
        let data = try await dataChannel.readAll()
        dataChannel.cancel()
        // Der Abschlusscode wird ausgewertet, nicht verworfen. Bleibt er aus
        // oder meldet er einen Fehler, kam die Uebertragung nicht zustande –
        // ohne diese Pruefung waere das von einem leeren Verzeichnis nicht zu
        // unterscheiden und die App zeigte stillschweigend "keine Notizen".
        let completion = try await readResponse(from: controlTask)
        guard completion.hasPrefix("226") || completion.hasPrefix("250") else {
            throw FTPSError.connectionFailed("Verzeichnisliste unvollständig: \(completion)")
        }

        let listing = String(data: data, encoding: .utf8)
                   ?? String(data: data, encoding: .isoLatin1) ?? ""
        return listing
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased().hasSuffix(".txt") }
    }

    private func fetchNote(filename: String) async throws -> Note {
        guard let controlTask else { throw FTPSError.notConnected }
        try await send("TYPE I\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)

        let dataChannel = try await openDataChannel(controlTask: controlTask)
        try await send("RETR \(filename)\r\n", to: controlTask)
        let reply = try await readResponse(from: controlTask)

        guard reply.hasPrefix("125") || reply.hasPrefix("150") else {
            dataChannel.cancel()
            throw FTPSError.downloadFailed
        }

        try await dataChannel.awaitReady()
        let data = try await dataChannel.readAll()
        dataChannel.cancel()
        _ = try? await readResponse(from: controlTask) // 226

        guard let content = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else {
            throw FTPSError.downloadFailed
        }
        return decode(content, filename: filename)
    }

    private func storeFile(filename: String, data: Data) async throws {
        guard let controlTask else { throw FTPSError.notConnected }
        try await send("TYPE I\r\n", to: controlTask)
        _ = try await readResponse(from: controlTask)

        let dataChannel = try await openDataChannel(controlTask: controlTask)
        try await send("STOR \(filename)\r\n", to: controlTask)
        let storResp = try await readResponse(from: controlTask)

        guard storResp.hasPrefix("125") || storResp.hasPrefix("150") else {
            dataChannel.cancel()
            throw FTPSError.uploadFailed("STOR abgelehnt: \(storResp)")
        }

        try await dataChannel.awaitReady()
        try await dataChannel.write(data)
        dataChannel.closeWrite()

        let completeResp = (try? await readResponse(from: controlTask)) ?? "226 implicit"
        dataChannel.cancel()
        if !completeResp.hasPrefix("226") && !completeResp.hasPrefix("250")
            && !completeResp.hasPrefix("4") && !completeResp.hasPrefix("5") {
            throw FTPSError.uploadFailed("Keine Transfer-Bestätigung: \(completeResp)")
        }
    }

    // MARK: - Passive data channel

    private func openDataChannel(
        controlTask: URLSessionStreamTask
    ) async throws -> FTPSDataChannel {
        let port = try await requestPassivePort(controlTask: controlTask)
        // The address from the server is ignored either way: PASV can only express IPv4 and the
        // Fritz!Box sometimes answers 0.0.0.0 or its WAN address, EPSV returns no address at all.
        // The data channel always goes back to the host the control connection already reached.
        let dataChannel = try FTPSDataChannel(
            host: normalizedHost,
            port: port,
            useTLS: encryptDataChannel,
            trustSelfSigned: settings.trustSelfSignedCertificates,
            timeout: dataTimeout
        )
        // Stoesst den Aufbau an, wartet aber NICHT auf den Handschlag: vsftpd
        // beginnt ihn erst nach dem Uebertragungsbefehl. Auf .ready wird nach
        // dem 150 gewartet – siehe FTPSDataChannel.start().
        dataChannel.start()
        return dataChannel
    }

    // EPSV (RFC 2428) first: it is the only passive command that works over IPv6, and it is
    // answered by vsftpd. PASV stays as the fallback for servers that reject EPSV — the
    // Fritz!Box does not list it in FEAT — but PASV cannot carry an IPv6 address, so over
    // IPv6 a refused EPSV is a hard error rather than a silent fallback into a timeout.
    private func requestPassivePort(controlTask: URLSessionStreamTask) async throws -> Int {
        if supportsEPSV != false {
            try await send("EPSV\r\n", to: controlTask)
            let epsvResp = try await readResponse(from: controlTask)
            if epsvResp.hasPrefix("229") {
                supportsEPSV = true
                return try parseEPSV(epsvResp)
            }
            supportsEPSV = false
            if hostIsIPv6Literal {
                throw FTPSError.connectionFailed(
                    "Server beherrscht EPSV nicht – über IPv6 ist keine Datenverbindung möglich: \(epsvResp)")
            }
        }

        try await send("PASV\r\n", to: controlTask)
        let pasvResp = try await readResponse(from: controlTask)
        guard pasvResp.hasPrefix("227") else {
            throw FTPSError.connectionFailed("PASV fehlgeschlagen: \(pasvResp)")
        }
        return try parsePASV(pasvResp).1
    }

    // MARK: - Low-level I/O

    private func send(_ command: String, to task: URLSessionStreamTask) async throws {
        let data = Data(command.utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: commandTimeout) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func readResponse(from task: URLSessionStreamTask) async throws -> String {
        while true {
            let line = try await readLine(from: task)
            guard line.count >= 4 else { continue }
            if line[line.index(line.startIndex, offsetBy: 3)] == " " { return line }
        }
    }

    private func readLine(from task: URLSessionStreamTask) async throws -> String {
        while true {
            if let range = readBuffer.range(of: Data("\r\n".utf8)) {
                let line = String(data: readBuffer[..<range.lowerBound], encoding: .utf8) ?? ""
                readBuffer.removeSubrange(..<range.upperBound)
                return line
            }
            if let range = readBuffer.range(of: Data("\n".utf8)) {
                var line = String(data: readBuffer[..<range.lowerBound], encoding: .utf8) ?? ""
                if line.hasSuffix("\r") { line.removeLast() }
                readBuffer.removeSubrange(..<range.upperBound)
                return line
            }
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                task.readData(ofMinLength: 1, maxLength: 4096, timeout: readTimeout) { data, _, error in
                    if let error { cont.resume(throwing: error) }
                    else { cont.resume(returning: data ?? Data()) }
                }
            }
            readBuffer.append(chunk)
        }
    }

    // MARK: - PASV / EPSV parsers

    // "229 Entering Extended Passive Mode (|||6446|)" — the character right after the
    // opening parenthesis is the delimiter, and only the port field is filled in.
    private func parseEPSV(_ response: String) throws -> Int {
        guard let open = response.firstIndex(of: "("),
              let close = response.lastIndex(of: ")"),
              open < close else {
            throw FTPSError.invalidResponse("EPSV-Format ungültig: \(response)")
        }
        let inner = response[response.index(after: open)..<close]
        guard let delimiter = inner.first else {
            throw FTPSError.invalidResponse("EPSV-Format ungültig: \(response)")
        }
        guard let portField = inner.split(separator: delimiter).last,
              let port = Int(portField),
              (1...65535).contains(port) else {
            throw FTPSError.invalidResponse("EPSV-Port ungültig: \(response)")
        }
        return port
    }

    private func parsePASV(_ response: String) throws -> (String, Int) {
        guard let open  = response.firstIndex(of: "("),
              let close = response.firstIndex(of: ")") else {
            throw FTPSError.invalidResponse("PASV-Format ungültig: \(response)")
        }
        let inner = String(response[response.index(after: open)..<close])
        let parts = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6 else {
            throw FTPSError.invalidResponse("PASV-Parameter ungültig: \(inner)")
        }
        return ("\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])", parts[4] * 256 + parts[5])
    }
}
