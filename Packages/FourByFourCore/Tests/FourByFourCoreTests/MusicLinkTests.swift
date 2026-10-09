import XCTest
@testable import FourByFourCore

final class MusicLinkTests: XCTestCase {
    func testSpotifyLinks() {
        XCTAssertEqual(MusicLink.spotifyURI(from: "spotify:playlist:37i9dQZF1DX76Wlfdnj7AP"), "spotify:playlist:37i9dQZF1DX76Wlfdnj7AP")
        XCTAssertEqual(MusicLink.spotifyURI(from: " https://open.spotify.com/playlist/37i9dQZF1DX76Wlfdnj7AP?si=abc "), "spotify:playlist:37i9dQZF1DX76Wlfdnj7AP")
        XCTAssertEqual(MusicLink.spotifyURI(from: "https://open.spotify.com/intl-de/album/1ATL5GLyefJaxhQzSPVrLX"), "spotify:album:1ATL5GLyefJaxhQzSPVrLX")
        XCTAssertNil(MusicLink.spotifyURI(from: "https://example.com/playlist/1"))
        XCTAssertNil(MusicLink.spotifyURI(from: "spotify:"))
        XCTAssertNil(MusicLink.spotifyURI(from: "my running mix"))
    }

    func testYouTubeLinks() {
        XCTAssertNotNil(MusicLink.youtubeURL(from: "https://www.youtube.com/playlist?list=PL123"))
        XCTAssertNotNil(MusicLink.youtubeURL(from: "https://music.youtube.com/playlist?list=PL123"))
        XCTAssertNotNil(MusicLink.youtubeURL(from: "https://youtu.be/abc"))
        XCTAssertNil(MusicLink.youtubeURL(from: "http://www.youtube.com/watch?v=abc"))
        XCTAssertNil(MusicLink.youtubeURL(from: "https://evil.example/youtube.com"))
    }
}
