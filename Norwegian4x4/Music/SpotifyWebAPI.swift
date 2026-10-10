import FourByFourCore
import Foundation

enum WebAPIError: Error, Equatable {
    /// 401: token missing or expired (~1 h).
    case needsAuthorization
    case rateLimited
    /// Any other failure, with the server's own error message if it sent one.
    case http(Int, String)
    case network(String)

    var message: String {
        switch self {
        case .needsAuthorization: return "Spotify needs to be connected again."
        case .rateLimited: return "Too many requests. Try again in a minute."
        case .http(let code, let detail): return detail.isEmpty ? "Error \(code)." : "Error \(code): \(detail)"
        case .network(let reason): return reason
        }
    }
}

/// The few Spotify Web API calls the auto mix needs, using the access token
/// from the App Remote authorization. Uses the endpoints that remain open to
/// Development Mode apps after the February 2026 changes (search limit 10,
/// `/me/playlists`, `/playlists/{id}/items`).
struct SpotifyWebAPI {
    static let searchPageSize = 10
    private static let base = URL(string: "https://api.spotify.com/v1/")!

    var token: String
    var session: URLSession = .shared

    func searchTracks(query: String, offset: Int) async throws -> [TrackCandidate] {
        // `market=from_token` would need the user-read-private scope (403
        // "Insufficient client scope"), so the device region is sent instead.
        // It limits results to tracks playable there and adds `is_playable`.
        let market = Locale.current.region?.identifier
        do {
            return try await search(query: query, offset: offset, market: market)
        } catch WebAPIError.http(403, _) where market != nil {
            return try await search(query: query, offset: offset, market: nil)
        }
    }

    private func search(query: String, offset: Int, market: String?) async throws -> [TrackCandidate] {
        var components = URLComponents(url: Self.base.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(Self.searchPageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let market { components.queryItems?.append(URLQueryItem(name: "market", value: market)) }
        let data = try await send(URLRequest(url: components.url!))
        return try SpotifySearchParser.tracks(from: data)
    }

    /// Creates a private playlist and returns its ID.
    func createPlaylist(name: String, description: String) async throws -> String {
        var request = URLRequest(url: Self.base.appendingPathComponent("me/playlists"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "public": false, "description": description])
        let data = try await send(request)
        struct Created: Decodable { var id: String }
        return try JSONDecoder().decode(Created.self, from: data).id
    }

    /// Replaces the playlist's contents (max 100 URIs). Throws `.http(404)`
    /// if the playlist was deleted by the user.
    func replaceItems(playlistID: String, uris: [String]) async throws {
        var request = URLRequest(url: Self.base.appendingPathComponent("playlists/\(playlistID)/items"))
        request.httpMethod = "PUT"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["uris": Array(uris.prefix(100))])
        _ = try await send(request)
    }

    /// Removes all occurrences of the tracks (`DELETE /playlists/{id}/items`;
    /// the body key is `items` since the February 2026 changes).
    func removeItems(playlistID: String, uris: [String]) async throws {
        var request = URLRequest(url: Self.base.appendingPathComponent("playlists/\(playlistID)/items"))
        request.httpMethod = "DELETE"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["items": uris.map { ["uri": $0] }])
        _ = try await send(request)
    }

    private func send(_ original: URLRequest) async throws -> Data {
        var request = original
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if request.httpBody != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.timeoutInterval = 15
        return try await HTTP.send(request, session: session)
    }
}

/// Tempo / energy lookup by Spotify track ID via ReccoBeats
/// (https://reccobeats.com; free, no key). Spotify's own audio-features
/// endpoint returns 403 for apps created after November 2024.
struct ReccoBeatsAPI {
    var session: URLSession = .shared

    /// A failing chunk is skipped (its tracks just count as "no data");
    /// callers treat an empty result as "service unavailable".
    func features(for trackIDs: [String]) async -> [String: AudioFeatures] {
        var result: [String: AudioFeatures] = [:]
        let ids = Array(Set(trackIDs))
        for start in stride(from: 0, to: ids.count, by: ReccoBeatsParser.maxIDsPerRequest) {
            let chunk = ids[start..<min(start + ReccoBeatsParser.maxIDsPerRequest, ids.count)]
            var components = URLComponents(string: "https://api.reccobeats.com/v1/audio-features")!
            components.queryItems = [URLQueryItem(name: "ids", value: chunk.joined(separator: ","))]
            var request = URLRequest(url: components.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            guard let data = try? await HTTP.send(request, session: session),
                  let features = try? ReccoBeatsParser.features(from: data) else { continue }
            result.merge(features) { first, _ in first }
        }
        return result
    }
}

enum HTTP {
    static func send(_ request: URLRequest, session: URLSession = .shared) async throws -> Data {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebAPIError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401: throw WebAPIError.needsAuthorization
        case 429: throw WebAPIError.rateLimited
        default: throw WebAPIError.http(status, errorMessage(in: data))
        }
    }

    /// Spotify sends {"error":{"status":403,"message":"…"}}; anything else is
    /// shown as (shortened) plain text.
    static func errorMessage(in data: Data) -> String {
        struct SpotifyError: Decodable { struct Inner: Decodable { var message: String? }; var error: Inner }
        if let parsed = try? JSONDecoder().decode(SpotifyError.self, from: data), let message = parsed.error.message {
            return message
        }
        return String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
