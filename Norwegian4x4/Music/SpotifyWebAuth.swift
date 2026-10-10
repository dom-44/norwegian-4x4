import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import UIKit

/// Spotify Web API sign-in for the auto mix (search + playlists).
///
/// The App Remote token from the Spotify app only allows remote control —
/// the Web API answers "Insufficient client scope" — so the mix signs in
/// separately with the standard Authorization Code flow with PKCE (no client
/// secret) in a system web sheet. The refresh token keeps it working without
/// signing in again every hour.
@Observable
@MainActor
final class SpotifyWebAuth: NSObject {
    static let scopes = ["playlist-modify-private", "playlist-read-private"]
    private static let accessKey = "spotify.web.accessToken"
    private static let refreshKey = "spotify.web.refreshToken"
    private static let expiresKey = "spotify.web.expiresAt"

    private(set) var isSignedIn = Keychain.get(SpotifyWebAuth.refreshKey) != nil
    @ObservationIgnored private var session: ASWebAuthenticationSession?

    private var clientID: String? { SpotifyMusicProvider.clientID }
    private var redirectURL: URL? { SpotifyMusicProvider.redirectURL }

    /// Opens the Spotify login sheet. Throws if cancelled or refused.
    func signIn() async throws {
        guard let clientID, let redirectURL, let scheme = redirectURL.scheme else { throw WebAPIError.http(0, "Spotify client ID missing.") }
        let verifier = Self.makeVerifier()
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: scheme) { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? WebAPIError.http(0, "Sign-in cancelled.")) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: WebAPIError.http(0, "Could not open the Spotify sign-in.")) }
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw WebAPIError.http(0, "Spotify sign-in: \(error)") }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { throw WebAPIError.http(0, "Spotify sign-in returned no code.") }

        try await requestToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURL.absoluteString,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    /// A valid access token, refreshed when it is about to expire.
    func validAccessToken() async throws -> String {
        if let token = Keychain.get(Self.accessKey),
           let expires = UserDefaults.standard.object(forKey: Self.expiresKey) as? Date, expires.timeIntervalSinceNow > 60 {
            return token
        }
        guard let refresh = Keychain.get(Self.refreshKey), let clientID else { throw WebAPIError.needsAuthorization }
        do {
            try await requestToken(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID])
        } catch WebAPIError.http(400, _) {
            // Refresh token revoked or expired.
            signOut()
            throw WebAPIError.needsAuthorization
        }
        guard let token = Keychain.get(Self.accessKey) else { throw WebAPIError.needsAuthorization }
        return token
    }

    func signOut() {
        Keychain.set(nil, for: Self.accessKey)
        Keychain.set(nil, for: Self.refreshKey)
        UserDefaults.standard.removeObject(forKey: Self.expiresKey)
        isSignedIn = false
    }

    private func requestToken(_ form: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)
        request.timeoutInterval = 15
        let data: Data
        do {
            data = try await HTTP.send(request)
        } catch WebAPIError.needsAuthorization {
            throw WebAPIError.http(400, "Spotify rejected the sign-in.")
        }

        struct TokenResponse: Decodable {
            var access_token: String
            var expires_in: Double
            var refresh_token: String?
        }
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        Keychain.set(response.access_token, for: Self.accessKey)
        // Spotify may rotate the refresh token; keep the old one otherwise.
        if let refresh = response.refresh_token { Keychain.set(refresh, for: Self.refreshKey) }
        UserDefaults.standard.set(Date().addingTimeInterval(response.expires_in), forKey: Self.expiresKey)
        isSignedIn = Keychain.get(Self.refreshKey) != nil
    }

    // MARK: PKCE

    private static func makeVerifier() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<64).map { _ in alphabet.randomElement()! })
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension SpotifyWebAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
