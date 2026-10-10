import FourByFourCore
import Foundation
import Observation
import UIKit
import os
#if canImport(SpotifyiOS)
import SpotifyiOS
#endif

/// Spotify playback control through the official Spotify iOS SDK (App Remote).
///
/// What the SDK does: it remote-controls the installed Spotify app over a
/// local connection. Audio is always played by the Spotify app itself; this
/// app never streams or extracts audio.
///
/// Requirements / limits (documented in the README):
/// * Spotify app installed and logged in; on-demand playback of a specific
///   playlist requires Spotify Premium.
/// * The first authorization (and any re-authorization after the token
///   expires, ~1 hour) switches to the Spotify app, so it is only ever started
///   by a user tap — never automatically.
/// * App Remote can only connect while the Spotify app is running; it is
///   most reliable when Spotify is already playing.
/// * Phase-based switching is attempted while this app is running in the
///   background (it is kept running by the heart-rate sensor), but iOS may
///   drop the connection at any time; failures fall back to spoken prompts.
@Observable
@MainActor
final class SpotifyMusicProvider: NSObject, MusicProvider {
    enum Status: Equatable {
        case sdkMissing
        case notConfigured
        case notInstalled
        case disconnected
        case authorizing
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .sdkMissing: return "Spotify SDK not included in this build"
            case .notConfigured: return "Add your Spotify client ID (see README)"
            case .notInstalled: return "Spotify app not installed"
            case .disconnected: return "Not connected"
            case .authorizing: return "Authorizing in Spotify…"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .failed(let message): return message
            }
        }
    }

    private(set) var status: Status = .disconnected
    private(set) var nowPlaying: String? = nil
    private(set) var isPaused = true
    let kind: MusicProviderKind = .spotify

    @ObservationIgnored private let log = Logger(subsystem: "Norwegian4x4", category: "Spotify")
    private static let tokenKey = "spotify.accessToken"
    private static let tokenIssuedKey = "spotify.tokenIssuedAt"
    private static let tokenScopesKey = "spotify.tokenScopes"
    /// Scopes beyond `app-remote-control`, for the auto mix (search needs none).
    private static let additionalScopes = ["playlist-modify-private", "playlist-read-private"]
    /// App Remote tokens last about an hour.
    private static let tokenLifetime: TimeInterval = 55 * 60
    @ObservationIgnored private var connectWaiters: [CheckedContinuation<Void, Error>] = []
    /// Called after a successful authorization (a fresh token is available).
    @ObservationIgnored var onAuthorized: (@MainActor () -> Void)?

    #if canImport(SpotifyiOS)
    @ObservationIgnored private var remote: SPTAppRemote?

    /// Created on first use (needs a configured client ID).
    private var appRemote: SPTAppRemote? {
        if let remote { return remote }
        guard let config = Self.configuration else { return nil }
        let created = SPTAppRemote(configuration: config, logLevel: .error)
        created.delegate = self
        remote = created
        return created
    }

    private static var configuration: SPTConfiguration? {
        guard let clientID = clientID, let redirect = redirectURL else { return nil }
        return SPTConfiguration(clientID: clientID, redirectURL: redirect)
    }
    #endif

    static var clientID: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String,
              !id.isEmpty, id != "YOUR_SPOTIFY_CLIENT_ID", !id.contains("$(") else { return nil }
        return id
    }

    static var redirectURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "SpotifyRedirectURI") as? String).flatMap(URL.init(string:))
    }

    override init() {
        super.init()
        refreshAvailability()
    }

    var sdkAvailable: Bool {
        #if canImport(SpotifyiOS)
        return true
        #else
        return false
        #endif
    }

    var isSpotifyInstalled: Bool {
        URL(string: "spotify:").map { UIApplication.shared.canOpenURL($0) } ?? false
    }

    var hasToken: Bool { Keychain.get(Self.tokenKey) != nil }

    /// The stored token if it is fresh and includes the playlist scopes;
    /// nil means the user has to tap Connect once more.
    var webAPIToken: String? {
        let defaults = UserDefaults.standard
        guard let token = Keychain.get(Self.tokenKey),
              defaults.stringArray(forKey: Self.tokenScopesKey) == Self.additionalScopes,
              let issued = defaults.object(forKey: Self.tokenIssuedKey) as? Date,
              Date().timeIntervalSince(issued) < Self.tokenLifetime else { return nil }
        return token
    }

    var capabilities: MusicCapabilities {
        let usable = sdkAvailable && Self.clientID != nil
        return MusicCapabilities(canSwitchAutomatically: usable, requiresForeground: false, canPauseResume: usable, canReadPlaybackState: usable)
    }

    func refreshAvailability() {
        if !sdkAvailable { status = .sdkMissing }
        else if Self.clientID == nil { status = .notConfigured }
        else if !isSpotifyInstalled { status = .notInstalled }
        else if status == .sdkMissing || status == .notConfigured || status == .notInstalled { status = .disconnected }
    }

    // MARK: User-initiated authorization (foreground only)

    /// Opens Spotify to authorize and starts `uri` (empty = resume last played).
    /// Only call from a user action: it switches apps.
    func authorizeAndPlay(uri: String?) {
        refreshAvailability()
        #if canImport(SpotifyiOS)
        guard let appRemote, isSpotifyInstalled else { return }
        status = .authorizing
        appRemote.authorizeAndPlayURI(uri ?? "", asRadio: false, additionalScopes: Self.additionalScopes) { [weak self] spotifyInstalled in
            Task { @MainActor in
                if !spotifyInstalled { self?.status = .notInstalled }
            }
        }
        #endif
    }

    /// Handles the redirect `norwegian4x4://spotify-login-callback?...`.
    /// Returns true if the URL belonged to Spotify.
    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        #if canImport(SpotifyiOS)
        guard let redirect = Self.redirectURL, url.scheme == redirect.scheme, let appRemote else { return false }
        let params = appRemote.authorizationParameters(from: url)
        if let token = params?[SPTAppRemoteAccessTokenKey] {
            Keychain.set(token, for: Self.tokenKey)
            UserDefaults.standard.set(Date(), forKey: Self.tokenIssuedKey)
            UserDefaults.standard.set(Self.additionalScopes, forKey: Self.tokenScopesKey)
            appRemote.connectionParameters.accessToken = token
            status = .connecting
            appRemote.connect()
            onAuthorized?()
        } else if let message = params?[SPTAppRemoteErrorDescriptionKey] {
            status = .failed("Spotify authorization failed: \(message)")
        }
        return true
        #else
        return false
        #endif
    }

    /// Quiet reconnect with the stored token (no app switch). Safe to call
    /// when returning to the foreground.
    func reconnectQuietly() {
        Task { try? await ensureConnected() }
    }

    func disconnect() {
        #if canImport(SpotifyiOS)
        if appRemote?.isConnected == true { appRemote?.disconnect() }
        #endif
    }

    func signOut() {
        disconnect()
        Keychain.set(nil, for: Self.tokenKey)
        status = .disconnected
        nowPlaying = nil
    }

    // MARK: MusicProvider

    func play(_ selection: MusicSelection, appIsActive: Bool) async throws {
        #if canImport(SpotifyiOS)
        try await ensureConnected()
        guard let player = appRemote?.playerAPI else { throw MusicProviderError.notConnected }
        if let index = selection.startIndex, index > 0, let item = await contentItem(for: selection.uri) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                player.playItem(item, skipToTrackIndex: index) { _, error in
                    if let error {
                        continuation.resume(throwing: MusicProviderError.commandFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.play(selection.uri) { _, error in
                if let error {
                    continuation.resume(throwing: MusicProviderError.commandFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
        #else
        throw MusicProviderError.notConfigured
        #endif
    }

    #if canImport(SpotifyiOS)
    /// Needed to start a playlist at a given track; nil falls back to playing
    /// the playlist from the top.
    private func contentItem(for uri: String) async -> (any SPTAppRemoteContentItem)? {
        guard let content = appRemote?.contentAPI else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<(any SPTAppRemoteContentItem)?, Never>) in
            content.fetchContentItem(forURI: uri) { result, _ in
                continuation.resume(returning: result as? any SPTAppRemoteContentItem)
            }
        }
    }
    #endif

    func pause() async throws {
        #if canImport(SpotifyiOS)
        guard let player = appRemote?.playerAPI, appRemote?.isConnected == true else { throw MusicProviderError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.pause { _, error in
                if let error { continuation.resume(throwing: MusicProviderError.commandFailed(error.localizedDescription)) } else { continuation.resume() }
            }
        }
        #else
        throw MusicProviderError.notConfigured
        #endif
    }

    func resume() async throws {
        #if canImport(SpotifyiOS)
        guard let player = appRemote?.playerAPI, appRemote?.isConnected == true else { throw MusicProviderError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.resume { _, error in
                if let error { continuation.resume(throwing: MusicProviderError.commandFailed(error.localizedDescription)) } else { continuation.resume() }
            }
        }
        #else
        throw MusicProviderError.notConfigured
        #endif
    }

    // MARK: Connection

    private func ensureConnected(timeout: TimeInterval = 6) async throws {
        #if canImport(SpotifyiOS)
        guard let appRemote else { throw MusicProviderError.notConfigured }
        if appRemote.isConnected { return }
        guard isSpotifyInstalled else { throw MusicProviderError.appNotInstalled }
        guard let token = Keychain.get(Self.tokenKey) else { throw MusicProviderError.notAuthorized }
        appRemote.connectionParameters.accessToken = token
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectWaiters.append(continuation)
            guard connectWaiters.count == 1 else { return }
            status = .connecting
            appRemote.connect()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishConnect(error: MusicProviderError.notConnected)
            }
        }
        #else
        throw MusicProviderError.notConfigured
        #endif
    }

    private func finishConnect(error: Error?) {
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }
}

#if canImport(SpotifyiOS)
extension SpotifyMusicProvider: SPTAppRemoteDelegate, SPTAppRemotePlayerStateDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in
            self.status = .connected
            self.finishConnect(error: nil)
            appRemote.playerAPI?.delegate = self
            appRemote.playerAPI?.subscribe(toPlayerState: { _, _ in })
            appRemote.playerAPI?.getPlayerState { [weak self] result, _ in
                guard let state = result as? SPTAppRemotePlayerState else { return }
                Task { @MainActor in self?.apply(state) }
            }
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        Task { @MainActor in
            // Usually: Spotify is not running, or the token expired.
            self.status = .failed("Could not reach Spotify. Open Spotify or tap Connect.")
            self.finishConnect(error: MusicProviderError.notConnected)
        }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        Task { @MainActor in
            self.status = .disconnected
            self.finishConnect(error: MusicProviderError.notConnected)
        }
    }

    nonisolated func playerStateDidChange(_ playerState: SPTAppRemotePlayerState) {
        Task { @MainActor in self.apply(playerState) }
    }

    private func apply(_ state: SPTAppRemotePlayerState) {
        nowPlaying = "\(state.track.name) — \(state.track.artist.name)"
        isPaused = state.isPaused
    }
}
#endif
