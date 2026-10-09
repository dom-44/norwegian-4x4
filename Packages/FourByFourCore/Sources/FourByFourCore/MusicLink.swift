import Foundation

/// Normalizes the links users paste from the Spotify / YouTube share sheets.
public enum MusicLink {
    static let spotifyTypes: Set<String> = ["playlist", "album", "track", "artist", "show", "episode"]

    /// Accepts `spotify:playlist:ID` or `https://open.spotify.com/[intl-xx/]playlist/ID?si=…`
    /// and returns a Spotify URI, or nil if the input is not a Spotify link.
    public static func spotifyURI(from input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("spotify:") {
            let parts = text.split(separator: ":")
            guard parts.count >= 3, spotifyTypes.contains(String(parts[parts.count - 2])) || parts.contains("user") else { return nil }
            return text
        }
        guard let components = URLComponents(string: text), components.host == "open.spotify.com" else { return nil }
        var segments = components.path.split(separator: "/").map(String.init)
        if let first = segments.first, first.hasPrefix("intl-") { segments.removeFirst() }
        guard segments.count >= 2, spotifyTypes.contains(segments[0]), !segments[1].isEmpty else { return nil }
        return "spotify:\(segments[0]):\(segments[1])"
    }

    /// Accepts https links on youtube.com, m.youtube.com, music.youtube.com and youtu.be.
    public static func youtubeURL(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased() else { return nil }
        let allowed = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"]
        return allowed.contains(host) ? url : nil
    }
}
