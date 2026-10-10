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

    // MARK: Curated lists

    func testCuratedIntervalListsAreUsable() {
        for genre in [MusicGenre.edm, .drumAndBass, .trance, .hardRock, .punk] {
            let tracks = CuratedCatalog.tracks(for: .highIntensity, genre: genre)
            XCTAssertGreaterThanOrEqual(tracks.count, 15, genre.rawValue)
            for track in tracks {
                XCTAssertGreaterThanOrEqual(track.energy, 0.75, track.title)
            }
        }
        XCTAssertFalse(CuratedCatalog.hasTracks(for: .highIntensity, genre: .chill))
    }

    func testEveryPhaseHasResearchedLists() {
        for slot in MusicSlot.allCases {
            let genres = CuratedCatalog.genres(for: slot)
            XCTAssertGreaterThanOrEqual(genres.count, 4, slot.rawValue)
            for genre in genres {
                let tracks = CuratedCatalog.tracks(for: slot, genre: genre)
                XCTAssertGreaterThanOrEqual(tracks.count, 5, "\(slot.rawValue) \(genre.rawValue)")
                XCTAssertTrue(tracks.allSatisfy { $0.id.count == 22 }, "Spotify IDs are 22 characters")
                XCTAssertEqual(Set(tracks.map(\.id)).count, tracks.count, "no duplicates in \(slot.rawValue) \(genre.rawValue)")
            }
        }
        XCTAssertTrue(CuratedCatalog.tracks(for: .coolDown, genre: .edm).allSatisfy { $0.energy <= 0.75 })
        let intervalIDs = Set(MusicGenre.allCases.flatMap { CuratedCatalog.tracks(for: .highIntensity, genre: $0).map(\.id) })
        let moderateIDs = Set(MusicGenre.allCases.flatMap { CuratedCatalog.tracks(for: .recovery, genre: $0).map(\.id) })
        XCTAssertTrue(intervalIDs.isDisjoint(with: moderateIDs), "interval songs stay special")
        // Defaults only use genres that have a list for the phase.
        let mix = AutoMixSettings()
        for slot in MusicSlot.allCases {
            XCTAssertTrue(mix[slot].allGenres.allSatisfy { CuratedCatalog.hasTracks(for: slot, genre: $0) }, slot.rawValue)
        }
    }

    func testRoundRobinMixesGenresEvenly() {
        let a = (0..<10).map { track("a\($0)") }, b = (0..<10).map { track("b\($0)") }, c = (0..<2).map { track("c\($0)") }
        var rng = SeededGenerator(state: 5)
        let picked = TrackPicker.pickRoundRobin(from: [a, b, c], count: 9, excluding: ["a1"], using: &rng)
        XCTAssertEqual(picked.count, 9)
        XCTAssertEqual(picked.filter { $0.id.hasPrefix("c") }.count, 2, "short list is used up")
        XCTAssertGreaterThanOrEqual(picked.filter { $0.id.hasPrefix("a") }.count, 3)
        XCTAssertGreaterThanOrEqual(picked.filter { $0.id.hasPrefix("b") }.count, 3)
        XCTAssertFalse(picked.contains { $0.id == "a1" })
    }

    // MARK: Ratings

    func testDislikedTracksAreNeverPicked() {
        var ratings = TrackRatings()
        ratings.dislike("a0")
        ratings.dislike("a1")
        let list = (0..<5).map { track("a\($0)") }
        for seed in 1...20 {
            var rng = SeededGenerator(state: UInt64(seed))
            let picked = TrackPicker.pickRoundRobin(from: [list], count: 5, ratings: ratings, using: &rng)
            XCTAssertEqual(Set(picked.map(\.id)), ["a2", "a3", "a4"])
        }
    }

    func testLikedTracksArePickedMoreOften() {
        var ratings = TrackRatings()
        ratings.like("t0")
        let list = (0..<20).map { track("t\($0)") }
        var likedHits = 0, otherHits = 0
        for seed in 1...400 {
            var rng = SeededGenerator(state: UInt64(seed))
            let picked = Set(TrackPicker.pickRoundRobin(from: [list], count: 5, ratings: ratings, using: &rng).map(\.id))
            if picked.contains("t0") { likedHits += 1 }
            if picked.contains("t1") { otherHits += 1 }
        }
        // Unrated: ~25 % of workouts (5 of 20); liked with weight 3: clearly more.
        XCTAssertGreaterThan(likedHits, otherHits * 2)
        XCTAssertLessThan(likedHits, 400, "liked songs still rotate, they are not forced in")
    }

    func testRatingsToggle() {
        var ratings = TrackRatings()
        ratings.like("x")
        XCTAssertEqual(ratings.rating(for: "x"), .liked)
        ratings.dislike("x")
        XCTAssertEqual(ratings.rating(for: "x"), .disliked)
        XCTAssertFalse(ratings.liked.contains("x"))
        ratings.clear("x")
        XCTAssertNil(ratings.rating(for: "x"))
        XCTAssertEqual(TrackRatings.trackID(fromURI: "spotify:track:4g6m1iaAsgdgDqgxGtvY0C"), "4g6m1iaAsgdgDqgxGtvY0C")
        XCTAssertNil(TrackRatings.trackID(fromURI: "spotify:playlist:abc"))
    }

    func testOldSlotWithoutGenreListDecodes() throws {
        let json = #"{"genre":"edm","tempo":{"bpm":{"lower":145,"upper":175},"minEnergy":0.75,"maxEnergy":1}}"#
        var slot = try JSONDecoder().decode(AutoMixSlot.self, from: Data(json.utf8))
        XCTAssertEqual(slot.allGenres, [.edm])
        slot.setGenres([.trance, .punk])
        XCTAssertEqual(slot.genre, .trance)
        XCTAssertEqual(slot.allGenres, [.trance, .punk])
        slot.setGenres([])
        XCTAssertEqual(slot.allGenres, [.trance, .punk], "an empty selection is ignored")
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
