//
//  SpotifySettingsSection.swift
//  boringNotch
//
//  Connects Spotify for instant "play <song/playlist>" requests.
//

import AppKit
import Defaults
import SwiftUI

struct SpotifySettingsSection: View {
    @ObservedObject private var spotify = SpotifyClient.shared
    @Default(.spotifyClientID) private var clientID

    var body: some View {
        Section {
            if let name = spotify.displayName {
                HStack {
                    Label("Connected as \(name)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") { spotify.disconnect() }
                }
            } else {
                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Redirect URI")
                    Spacer()
                    Text(SpotifyClient.redirectURI)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SpotifyClient.redirectURI, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
                HStack {
                    Button("Open Spotify Developer Dashboard") {
                        NSWorkspace.shared.open(URL(string: "https://developer.spotify.com/dashboard")!)
                    }
                    Spacer()
                    if spotify.isConnecting { ProgressView().controlSize(.small) }
                    Button(spotify.isConnecting ? "Waiting for browser…" : "Connect Spotify") { spotify.connect() }
                        .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || spotify.isConnecting)
                }
            }
            if let error = spotify.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text("Lets “play <song, artist, album or playlist>” start instantly. Create a free app in the Spotify Developer Dashboard (Web API), add the redirect URI above, then paste its Client ID here. No secret is needed. Without this, music requests open a Spotify search instead.")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}
