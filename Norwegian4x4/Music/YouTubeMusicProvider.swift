import FourByFourCore
import UIKit

/// YouTube / YouTube Music via the official apps only.
///
/// There is no official iOS API for controlling playback in the YouTube or
/// YouTube Music apps, and the embeddable IFrame player stops when the screen
/// locks or the app is backgrounded (and must stay visible per YouTube's
/// terms). So this provider:
/// * opens the selected playlist/video link in the official app (user tap), and
/// * never switches automatically — phase changes produce spoken / on-screen
///   prompts with a one-tap "Open" button instead.
/// Background playback in the YouTube apps depends on the user's YouTube
/// Premium subscription; this app does not change that.
@MainActor
final class YouTubeMusicProvider: MusicProvider {
    let kind: MusicProviderKind = .youtube
    let capabilities = MusicCapabilities(canSwitchAutomatically: false, requiresForeground: true, canPauseResume: false, canReadPlaybackState: false)

    var isYouTubeInstalled: Bool { URL(string: "youtube://").map { UIApplication.shared.canOpenURL($0) } ?? false }
    var isYouTubeMusicInstalled: Bool { URL(string: "youtubemusic://").map { UIApplication.shared.canOpenURL($0) } ?? false }

    /// Opens the link in the YouTube / YouTube Music app (universal link), or
    /// Safari when the app is not installed. Only call from a user action.
    func open(_ selection: MusicSelection) {
        guard let url = MusicLink.youtubeURL(from: selection.uri) else { return }
        UIApplication.shared.open(url)
    }

    func play(_ selection: MusicSelection, appIsActive: Bool) async throws { throw MusicProviderError.unsupported }
    func pause() async throws { throw MusicProviderError.unsupported }
    func resume() async throws { throw MusicProviderError.unsupported }
}
