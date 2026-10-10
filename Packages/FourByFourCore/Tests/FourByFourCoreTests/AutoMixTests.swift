import XCTest
@testable import FourByFourCore

/// Deterministic RNG so shuffles are reproducible in tests.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class AutoMixTests: XCTestCase {
    private func track(_ id: String, artist: String? = nil) -> TrackCandidate {
        TrackCandidate(id: id, uri: "spotify:track:\(id)", name: "Song \(id)", artist: artist ?? "Artist \(id)")
    }

    // MARK: Tempo profile

    func testHalfAndDoubleTempoAreRecognised() {
        let high = TempoProfile.standard(for: .highIntensity) // 145–175
        XCTAssertEqual(high.matchingTempo(87), 174)           // drum & bass reported at half time
        XCTAssertEqual(high.matchingTempo(160), 160)
        XCTAssertNil(high.matchingTempo(120))
        let cool = TempoProfile.standard(for: .coolDown)      // 70–100
        XCTAssertEqual(cool.matchingTempo(180), 90)
    }

    func testDistanceIsZeroInsideRanges() {
        let warm = TempoProfile.standard(for: .warmUp)
        XCTAssertEqual(warm.distance(tempo: 120, energy: 0.6), 0)
        XCTAssertEqual(warm.distance(tempo: 135, energy: 0.6), 5, accuracy: 0.001)
        XCTAssertEqual(warm.distance(tempo: 120, energy: 0.95), 10, accuracy: 0.001)
    }

    // MARK: Picker

    func testPicksOnlyFittingTracksFirst() {
        let profile = TempoProfile.standard(for: .highIntensity)
        let candidates = [track("slow"), track("fit1"), track("fit2"), track("calm"), track("nodata")]
        let features: [String: AudioFeatures] = [
            "slow": AudioFeatures(tempo: 100, energy: 0.9),
            "fit1": AudioFeatures(tempo: 160, energy: 0.9),
            "fit2": AudioFeatures(tempo: 86, energy: 0.8),   // 172 felt
            "calm": AudioFeatures(tempo: 160, energy: 0.2),
        ]
        var rng = SeededGenerator(state: 1)
        let picked = TrackPicker.pick(from: candidates, features: features, profile: profile, count: 5, using: &rng)
        XCTAssertEqual(Set(picked.map(\.id)), ["fit1", "fit2"])
    }

    func testNearMissesFillUpAfterExactFits() {
        let profile = TempoProfile.standard(for: .highIntensity)
        let features: [String: AudioFeatures] = [
            "fit": AudioFeatures(tempo: 150, energy: 0.9),
            "close": AudioFeatures(tempo: 140, energy: 0.9),  // 5 BPM short
            "closer": AudioFeatures(tempo: 143, energy: 0.9), // 2 BPM short
            "far": AudioFeatures(tempo: 110, energy: 0.9),
        ]
        var rng = SeededGenerator(state: 7)
        let picked = TrackPicker.pick(from: [track("far"), track("close"), track("closer"), track("fit")],
                                      features: features, profile: profile, count: 3, using: &rng)
        XCTAssertEqual(picked.map(\.id), ["fit", "closer", "close"])
    }

    func testLimitsTracksPerArtistAndDuplicates() {
        let profile = TempoProfile.standard(for: .highIntensity)
        let candidates = [track("a", artist: "X"), track("b", artist: "x"), track("c", artist: "X"), track("a", artist: "X"), track("d")]
        let features = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].map { ($0, AudioFeatures(tempo: 160, energy: 0.9)) })
        var rng = SeededGenerator(state: 3)
        let picked = TrackPicker.pick(from: candidates, features: features, profile: profile, count: 10, using: &rng)
        XCTAssertEqual(picked.count, 3)
        XCTAssertEqual(picked.filter { $0.artist.lowercased() == "x" }.count, TrackPicker.maxPerArtist)
        XCTAssertEqual(Set(picked.map(\.id)).count, picked.count)
    }

    func testShuffleVariesWithSeed() {
        let profile = TempoProfile.standard(for: .highIntensity)
        let ids = (0..<20).map { "t\($0)" }
        let features = Dictionary(uniqueKeysWithValues: ids.map { ($0, AudioFeatures(tempo: 160, energy: 0.9)) })
        var rng1 = SeededGenerator(state: 1), rng2 = SeededGenerator(state: 2)
        let a = TrackPicker.pick(from: ids.map { track($0) }, features: features, profile: profile, count: 8, using: &rng1)
        let b = TrackPicker.pick(from: ids.map { track($0) }, features: features, profile: profile, count: 8, using: &rng2)
        XCTAssertEqual(a.count, 8)
        XCTAssertNotEqual(a.map(\.id), b.map(\.id))
    }

    // MARK: Parsing

    func testParsesSpotifySearch() throws {
        let json = """
        {"tracks":{"href":"x","items":[
          {"id":"1","uri":"spotify:track:1","name":"One","artists":[{"name":"A"}],"is_playable":true},
          {"id":"2","uri":"spotify:track:2","name":"Two","artists":[{"name":"B"}],"is_playable":false},
          {"id":null,"uri":"spotify:local:x","name":"Local","artists":[],"is_local":true},
          null,
          {"id":"3","uri":"spotify:track:3","name":"Three","artists":[]}
        ],"limit":10,"offset":0,"total":3}}
        """
        let tracks = try SpotifySearchParser.tracks(from: Data(json.utf8))
        XCTAssertEqual(tracks.map(\.id), ["1", "3"])
        XCTAssertEqual(tracks[0].artist, "A")
        XCTAssertEqual(tracks[1].artist, "")
    }

    func testParsesReccoBeatsFeatures() throws {
        // Shape as returned by api.reccobeats.com/v1/audio-features (Oct 2026).
        let json = """
        {"content":[
          {"id":"ef0e9524-99b3-483c-9690-6abd71e6064d","href":"https://open.spotify.com/track/7qiZfU4dY1lWllzX7mPBI3","isrc":"GBAHS1600463","acousticness":0.581,"danceability":0.825,"energy":0.652,"instrumentalness":0.0,"key":1,"liveness":0.0931,"loudness":-3.183,"mode":0,"speechiness":0.0802,"tempo":95.977,"valence":0.931},
          {"id":"x","href":"https://example.com/track/abc","energy":0.5,"tempo":120},
          {"id":"y","href":"https://open.spotify.com/track/zero","energy":0.5,"tempo":0}
        ]}
        """
        let features = try ReccoBeatsParser.features(from: Data(json.utf8))
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features["7qiZfU4dY1lWllzX7mPBI3"]?.tempo ?? 0, 95.977, accuracy: 0.001)
        XCTAssertEqual(features["7qiZfU4dY1lWllzX7mPBI3"]?.energy ?? 0, 0.652, accuracy: 0.001)
    }

    // MARK: Settings

    func testOldSettingsWithoutAutoMixStillDecode() throws {
        let json = """
        {"provider":"spotify","autoSwitch":true,"spokenSwitchPrompts":true,
         "warmUp":{"title":"Easy","uri":"spotify:playlist:easy"}}
        """
        let prefs = try JSONDecoder().decode(MusicPreferences.self, from: Data(json.utf8))
        XCTAssertNil(prefs.autoMix)
        XCTAssertFalse(prefs.autoMixEnabled)
        XCTAssertEqual(prefs.warmUp, MusicSelection(title: "Easy", uri: "spotify:playlist:easy"))
    }

    func testAutoMixRoundTrips() throws {
        var prefs = MusicPreferences(provider: .spotify)
        var mix = AutoMixSettings()
        mix.highIntensity.genre = .drumAndBass
        mix.highIntensity.tempo.bpm = BPMRange(lower: 160, upper: 180)
        prefs.autoMix = mix
        let decoded = try JSONDecoder().decode(MusicPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded, prefs)
        XCTAssertTrue(decoded.autoMixEnabled)
    }

    func testEveryGenreHasQueries() {
        for genre in MusicGenre.allCases {
            XCTAssertFalse(genre.searchQueries.isEmpty, genre.rawValue)
        }
    }
}

@MainActor
final class AutoMixRotationTests: XCTestCase {
    func testRepeatedPhasesStartFurtherIntoGeneratedPlaylist() async {
        let provider = MockMusicProvider()
        var prefs = MusicPreferences(provider: .spotify)
        prefs.highIntensity = MusicSelection(title: "High", uri: "spotify:playlist:high", trackCount: 5)
        prefs.recovery = MusicSelection(title: "Easy", uri: "spotify:playlist:easy", trackCount: 12)
        let c = MusicCoordinator(provider: provider, preferences: prefs)

        for _ in 0..<4 {
            await c.phaseDidStart(.interval, appIsActive: true)
            await c.phaseDidStart(.recovery, appIsActive: true)
        }
        let highStarts = provider.played.filter { $0.uri.hasSuffix("high") }.map(\.startIndex)
        let easyStarts = provider.played.filter { $0.uri.hasSuffix("easy") }.map(\.startIndex)
        XCTAssertEqual(highStarts, [0, 2, 4, 1]) // wraps around a 5-track playlist
        XCTAssertEqual(easyStarts, [0, 2, 4, 6])
    }

    func testLinkSelectionsAreNotRotated() async {
        let provider = MockMusicProvider()
        var prefs = MusicPreferences(provider: .spotify)
        prefs.highIntensity = MusicSelection(title: "High", uri: "spotify:playlist:high")
        prefs.recovery = MusicSelection(title: "Easy", uri: "spotify:playlist:easy")
        let c = MusicCoordinator(provider: provider, preferences: prefs)
        await c.phaseDidStart(.interval, appIsActive: true)
        await c.phaseDidStart(.recovery, appIsActive: true)
        await c.phaseDidStart(.interval, appIsActive: true)
        XCTAssertEqual(provider.played.map(\.startIndex), [nil, nil, nil])
    }

    func testUpdateSelectionsKeepsSessionState() async {
        let provider = MockMusicProvider()
        let c = MusicCoordinator(provider: provider, preferences: MusicPreferences(provider: .spotify))
        let none = await c.phaseDidStart(.warmUp, appIsActive: true)
        XCTAssertEqual(none, .nothing)
        var prefs = MusicPreferences(provider: .spotify)
        prefs.highIntensity = MusicSelection(title: "High", uri: "spotify:playlist:high", trackCount: 12)
        c.updateSelections(prefs)
        await c.phaseDidStart(.interval, appIsActive: true)
        await c.phaseDidStart(.recovery, appIsActive: true)
        await c.phaseDidStart(.interval, appIsActive: true)
        XCTAssertEqual(provider.played.map(\.startIndex), [0, 2])
    }
}
