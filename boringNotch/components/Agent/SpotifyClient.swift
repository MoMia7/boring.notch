//
//  SpotifyClient.swift
//  boringNotch
//
//  Minimal Spotify Web API client for instant music requests: PKCE login (client ID
//  only, no secret), search, the user's playlists, liking tracks, and playback via
//  the Spotify app's AppleScript interface (works without Premium).
//

import AppKit
import CryptoKit
import Defaults
import Foundation
import Network
import OSLog
import Security

private let log = Logger(subsystem: "io.otron.notch", category: "spotify")

extension Defaults.Keys {
    static let spotifyClientID = Key<String>("spotifyClientID", default: "")
}

struct SpotifyItem: Equatable {
    let uri: String
    let name: String
    let subtitle: String
}

@MainActor
final class SpotifyClient: ObservableObject {
    static let shared = SpotifyClient()

    static let redirectPort: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:43821/callback"
    private static let scopes = [
        "playlist-read-private", "playlist-read-collaborative", "user-library-read",
        "user-library-modify", "user-read-playback-state", "user-read-currently-playing",
    ].joined(separator: " ")

    @Published private(set) var displayName: String?
    @Published private(set) var isConnecting = false
    @Published var lastError: String?

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var userID: String?
    private var playlists: [SpotifyItem] = []
    private var playlistsFetchedAt = Date.distantPast
    private var listener: NWListener?

    var isConnected: Bool { SpotifyKeychain.load() != nil }
    var cachedPlaylistNames: [String] { playlists.map(\.name) }

    private init() {
        if isConnected { Task { await refreshProfile() } }
    }

    // MARK: - Login (Authorization Code + PKCE)

    func connect() {
        let clientID = Defaults[.spotifyClientID].trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty else {
            lastError = "Paste your Spotify app's Client ID first."
            return
        }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = Self.randomString(16)
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: Self.scopes),
            .init(name: "state", value: state),
        ]
        isConnecting = true
        lastError = nil
        do {
            try listenForCallback { [weak self] code, returnedState in
                guard let self else { return }
                guard returnedState == state, let code else {
                    self.finishConnecting(error: "Spotify login was cancelled or didn't match.")
                    return
                }
                Task { await self.exchange(code: code, verifier: verifier, clientID: clientID) }
            }
            NSWorkspace.shared.open(components.url!)
        } catch {
            finishConnecting(error: "Couldn't listen on port \(Self.redirectPort): \(error.localizedDescription)")
        }
    }

    func disconnect() {
        SpotifyKeychain.delete()
        accessToken = nil
        displayName = nil
        playlists = []
    }

    private func finishConnecting(error: String?) {
        isConnecting = false
        lastError = error
        listener?.cancel()
        listener = nil
    }

    private func listenForCallback(_ handler: @escaping @MainActor (String?, String?) -> Void) throws {
        listener?.cancel()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: Self.redirectPort)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let items = URLComponents(string: "http://127.0.0.1" + path)?.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let state = items.first { $0.name == "state" }?.value
                let body = code != nil
                    ? "<h2 style='font-family:-apple-system'>Spotify connected to Notch. You can close this tab.</h2>"
                    : "<h2 style='font-family:-apple-system'>Spotify login didn't complete.</h2>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                guard path.hasPrefix("/callback") else { return }
                Task { @MainActor in handler(code, state) }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func exchange(code: String, verifier: String, clientID: String) async {
        let result = await tokenRequest([
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
            "client_id": clientID, "code_verifier": verifier,
        ])
        finishConnecting(error: result ? nil : (lastError ?? "Token exchange failed."))
        if result { await refreshProfile() }
    }

    private func tokenRequest(_ form: [String: String]) async -> Bool {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (response as? HTTPURLResponse)?.statusCode == 200,
              let token = json["access_token"] as? String else {
            lastError = "Spotify token request failed."
            return false
        }
        accessToken = token
        accessExpiry = Date().addingTimeInterval((json["expires_in"] as? Double ?? 3600) - 60)
        if let refresh = json["refresh_token"] as? String { SpotifyKeychain.save(refresh) }
        return true
    }

    private func validToken() async -> String? {
        if let accessToken, Date() < accessExpiry { return accessToken }
        guard let refresh = SpotifyKeychain.load() else { return nil }
        let clientID = Defaults[.spotifyClientID]
        guard await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]) else {
            return nil
        }
        return accessToken
    }

    // MARK: - Web API

    private func api(_ path: String, method: String = "GET", query: [String: String] = [:]) async -> Any? {
        guard let token = await validToken() else { return nil }
        var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { components.queryItems = query.map { .init(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.timeoutInterval = 5
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            log.error("spotify \(method, privacy: .public) \(path, privacy: .public) -> \(status)")
            return nil
        }
        if data.isEmpty { return [String: Any]() }
        return try? JSONSerialization.jsonObject(with: data)
    }

    func refreshProfile() async {
        guard let me = await api("/me") as? [String: Any] else { return }
        displayName = me["display_name"] as? String ?? me["id"] as? String
        userID = me["id"] as? String
        _ = await myPlaylists()
    }

    /// kind: track | artist | album | playlist
    func search(_ query: String, kind: String, limit: Int = 6) async -> [SpotifyItem] {
        guard let json = await api("/search", query: ["q": query, "type": kind, "limit": "\(limit)"]) as? [String: Any],
              let items = (json[kind + "s"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let uri = item["uri"] as? String, let name = item["name"] as? String else { return nil }
            let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ")
            let owner = (item["owner"] as? [String: Any])?["display_name"] as? String
            return SpotifyItem(uri: uri, name: name, subtitle: artists ?? owner ?? "")
        }
    }

    func myPlaylists() async -> [SpotifyItem] {
        if !playlists.isEmpty, Date().timeIntervalSince(playlistsFetchedAt) < 600 { return playlists }
        var all: [SpotifyItem] = []
        var offset = 0
        while offset < 250 {
            guard let json = await api("/me/playlists", query: ["limit": "50", "offset": "\(offset)"]) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { break }
            all += items.compactMap { item in
                guard let uri = item["uri"] as? String, let name = item["name"] as? String else { return nil }
                return SpotifyItem(uri: uri, name: name, subtitle: "")
            }
            if items.count < 50 { break }
            offset += 50
        }
        if !all.isEmpty {
            playlists = all
            playlistsFetchedAt = Date()
        }
        return playlists
    }

    var likedSongsURI: String? { userID.map { "spotify:user:\($0):collection" } }

    /// Saves the currently playing Spotify track to Liked Songs.
    func likeCurrentTrack() async -> String? {
        guard let uri = await Self.appleScript("tell application \"Spotify\" to return id of current track"),
              uri.hasPrefix("spotify:track:") else { return nil }
        // Feb 2026: PUT /me/tracks was replaced by the unified PUT /me/library (takes URIs).
        guard await api("/me/library", method: "PUT", query: ["uris": uri]) != nil else { return nil }
        return await Self.appleScript("tell application \"Spotify\" to return name of current track")
    }

    // MARK: - Playback (Spotify app)

    @discardableResult
    func play(uri: String) async -> Bool {
        await Self.appleScript("tell application \"Spotify\" to play track \"\(uri)\"") != nil
    }

    func toggleShuffle() async -> Bool? {
        guard let value = await Self.appleScript("tell application \"Spotify\"\nset shuffling to not shuffling\nreturn shuffling\nend tell") else { return nil }
        return value == "true"
    }

    /// AppleScript runs on its own serial queue: launching Spotify can take seconds and must
    /// not block the notch UI.
    private static let scriptQueue = DispatchQueue(label: "io.otron.notch.applescript")

    @discardableResult
    static func appleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            scriptQueue.async { continuation.resume(returning: runAppleScript(source)) }
        }
    }

    private nonisolated static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            log.error("applescript failed: \(error, privacy: .public)")
            return nil
        }
        return result?.stringValue ?? ""
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

enum SpotifyKeychain {
    private static let service = "io.otron.notch.spotify"
    private static let account = "refresh-token"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: account, kSecValueData as String: Data(token.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
