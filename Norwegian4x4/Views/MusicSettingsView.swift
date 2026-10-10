import FourByFourCore
import SwiftUI

struct MusicSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let prefs = model.settings.music
        Form {
            Section {
                Picker("Provider", selection: $model.settings.music.provider) {
                    ForEach(MusicProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            } footer: {
                Text(providerFooter(prefs.provider))
            }

            if prefs.provider == .spotify { spotifySection }

            if prefs.provider == .spotify {
                Section {
                    Toggle("Pick songs by genre", isOn: autoMixEnabled)
                } footer: {
                    Text("Choose a genre per phase. Before each workout the app finds songs whose tempo and energy fit the phase and puts them into private “4x4 ·” playlists in your Spotify account. Tempo data comes from ReccoBeats.")
                }
            }

            if prefs.autoMixEnabled, let mix = prefs.autoMix {
                Section {
                    ForEach(MusicSlot.allCases) { slot in
                        NavigationLink {
                            AutoMixSlotEditor(slot: slot)
                        } label: {
                            LabeledContent(slot.displayName, value: mix[slot].allGenres.map(\.displayName).joined(separator: ", "))
                        }
                    }
                    AutoMixStatusView()
                } header: {
                    Text("Genre per phase")
                }
                let ratings = model.music.autoMix.ratings
                Section {
                    LabeledContent("Liked (played more often)", value: "\(ratings.liked.count)")
                    LabeledContent("Removed", value: "\(ratings.disliked.count)")
                    if !ratings.liked.isEmpty || !ratings.disliked.isEmpty {
                        Button("Reset ratings", role: .destructive) { model.music.resetRatings() }
                    }
                } header: {
                    Text("Your ratings")
                } footer: {
                    Text("Rate the playing song with 👍 / 👎 on the workout screen.")
                }
            } else if prefs.provider == .spotify || prefs.provider == .youtube || prefs.provider == .manual {
                Section {
                    ForEach(MusicSlot.allCases) { slot in
                        NavigationLink {
                            MusicSelectionEditor(slot: slot, provider: prefs.provider)
                        } label: {
                            LabeledContent(slot.displayName, value: prefs[slot]?.title ?? "Not set")
                        }
                    }
                } header: {
                    Text("Music per phase")
                } footer: {
                    Text(prefs.provider == .manual
                         ? "Optional names are used in the spoken prompts, e.g. “Switch music to Power Mix”."
                         : "Paste a share link from the \(prefs.provider.displayName) app. Using the same playlist for several phases avoids restarting it.")
                }
            }

            if prefs.provider == .spotify {
                Section {
                    LabeledContent("Songs with a start point", value: "\(model.music.learnedStartCount)")
                    if model.music.learnedStartCount > 0 {
                        Button("Reset start points", role: .destructive) { model.music.resetStartPoints() }
                    }
                } header: {
                    Text("Interval start points")
                } footer: {
                    Text("During intervals, ⏩ skips 15 s ahead and remembers the spot: next time the song starts right there. Hold ⏩ to go back to the beginning and forget it.")
                }
            }

            if prefs.provider != .none {
                Section {
                    if prefs.provider == .spotify {
                        Toggle("Switch automatically at phase changes", isOn: $model.settings.music.autoSwitch)
                    }
                    Toggle("Spoken switch prompts", isOn: $model.settings.music.spokenSwitchPrompts)
                } footer: {
                    Text("If automatic switching is off or fails, you get a spoken prompt and an Open button on the workout screen. A music failure never affects the workout timer.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Music")
        .onAppear { model.music.spotify.refreshAvailability() }
    }

    private var spotifySection: some View {
        let spotify = model.music.spotify
        return Section {
            LabeledContent("Status", value: spotify.status.label)
            if let playing = spotify.nowPlaying {
                LabeledContent("Now playing", value: playing)
            }
            switch spotify.status {
            case .sdkMissing, .notConfigured:
                EmptyView()
            case .notInstalled:
                Link("Get Spotify from the App Store", destination: URL(string: "https://apps.apple.com/app/spotify-music-and-podcasts/id324684580")!)
            case .connected:
                Button("Disconnect") { spotify.disconnect() }
                Button("Sign out of Spotify", role: .destructive) { spotify.signOut(); model.music.webAuth.signOut() }
            default:
                Button(spotify.hasToken ? "Reconnect to Spotify" : "Connect Spotify") {
                    spotify.connectWithoutPlaying()
                }
                if spotify.hasToken {
                    Button("Sign out of Spotify", role: .destructive) { spotify.signOut(); model.music.webAuth.signOut() }
                }
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text("Uses the official Spotify iOS SDK to remote-control the Spotify app. Requires the Spotify app; playing a specific playlist requires Spotify Premium. Connecting briefly opens Spotify and returns here. Spotify must be running for automatic switching; while the phone is locked switching is attempted but not guaranteed by iOS.")
        }
    }

    private var autoMixEnabled: Binding<Bool> {
        Binding {
            model.settings.music.autoMix?.enabled == true
        } set: { on in
            var mix = model.settings.music.autoMix ?? AutoMixSettings()
            mix.enabled = on
            model.settings.music.autoMix = mix
        }
    }

    private func providerFooter(_ kind: MusicProviderKind) -> String {
        switch kind {
        case .none: return "Coaching only. Other apps' audio is ducked briefly during announcements."
        case .manual: return "Play music from any app. The workout tells you when to switch. Always available."
        case .spotify: return "Automatic playlist switching via the official Spotify SDK, with spoken fallback."
        case .youtube: return "Opens your playlists in the official YouTube or YouTube Music app. YouTube offers no playback-control API, so switching is manual (one tap). Background / locked-screen playback in YouTube requires YouTube Premium."
        }
    }
}

struct MusicSelectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var slot: MusicSlot
    var provider: MusicProviderKind

    @State private var title = ""
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name (e.g. Power Mix)", text: $title)
                if provider != .manual {
                    TextField(provider == .spotify ? "Spotify link or URI" : "YouTube link", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Paste from clipboard") {
                        if let text = UIPasteboard.general.string { link = text }
                    }
                }
            } footer: {
                Text(provider == .spotify
                     ? "In Spotify: ••• › Share › Copy link to playlist. Links like https://open.spotify.com/playlist/… or spotify:playlist:… work."
                     : provider == .youtube ? "In YouTube or YouTube Music: Share › Copy link." : "")
            }
            if let error {
                Text(error).foregroundStyle(.orange)
            }
            Section {
                Button("Save") { save() }.font(.headline)
                if model.settings.music[slot] != nil {
                    Button("Clear", role: .destructive) {
                        model.settings.music[slot] = nil
                        dismiss()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(slot.displayName)
        .onAppear {
            title = model.settings.music[slot]?.title ?? ""
            link = model.settings.music[slot]?.uri ?? ""
        }
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .spotify:
            guard let uri = MusicLink.spotifyURI(from: link) else { error = "That doesn't look like a Spotify link."; return }
            model.settings.music[slot] = MusicSelection(title: name.isEmpty ? "Spotify \(uri.split(separator: ":").dropLast().last ?? "playlist")" : name, uri: uri)
        case .youtube:
            guard let url = MusicLink.youtubeURL(from: link) else { error = "Use an https://youtube.com, music.youtube.com or youtu.be link."; return }
            model.settings.music[slot] = MusicSelection(title: name.isEmpty ? "YouTube playlist" : name, uri: url.absoluteString)
        case .manual, .none:
            model.settings.music[slot] = name.isEmpty ? nil : MusicSelection(title: name, uri: "")
        }
        dismiss()
    }
}

struct AutoMixSlotEditor: View {
    @Environment(AppModel.self) private var model
    var slot: MusicSlot

    var body: some View {
        let standard = TempoProfile.standard(for: slot)
        Form {
            Section {
                ForEach(visibleGenres) { genre in
                    Button {
                        toggle(genre)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(genre.displayName).foregroundStyle(.primary)
                                let count = CuratedCatalog.tracks(for: slot, genre: genre).count
                                Text(count > 0 ? "\(count) researched songs" : "No researched list: found by search")
                                    .font(.caption).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            if selectedGenres.contains(genre) {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(selectedGenres.contains(genre) ? .isSelected : [])
                }
            } header: {
                Text("Genres")
            } footer: {
                Text("Pick one or more; the playlist mixes them evenly. Every song was chosen for this phase and checked for tempo and energy. Songs you like come up more often; songs you dislike are removed.")
            }
            if selectedGenres.contains(where: { !CuratedCatalog.hasTracks(for: slot, genre: $0) }) {
                tempoSection(standard: standard)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(slot.displayName)
    }

    /// Only relevant for genres found by search (from older settings).
    private func tempoSection(standard: TempoProfile) -> some View {
            Section {
                Stepper("From \(tempo.bpm.lower) BPM", value: binding(\.tempo.bpm.lower), in: 50...max(50, tempo.bpm.upper - 5), step: 5)
                Stepper("To \(tempo.bpm.upper) BPM", value: binding(\.tempo.bpm.upper), in: min(220, tempo.bpm.lower + 5)...220, step: 5)
                if tempo != standard {
                    Button("Reset to \(standard.bpm.label) BPM") { model.settings.music.autoMix?[slot].tempo = standard }
                }
            } header: {
                Text("Song tempo")
            } footer: {
                Text("Songs analysed at half or double tempo count too (a 174 BPM drum & bass track is often listed as 87). Energy is matched automatically: \(Int(standard.minEnergy * 100))–\(Int(standard.maxEnergy * 100)) %.")
            }
    }

    /// Researched genres, plus any older search-based genre still selected
    /// (so it can be unticked).
    private var visibleGenres: [MusicGenre] {
        let curated = CuratedCatalog.genres(for: slot)
        return curated + selectedGenres.filter { !curated.contains($0) }
    }

    private var tempo: TempoProfile { model.settings.music.autoMix?[slot].tempo ?? .standard(for: slot) }

    private var selectedGenres: [MusicGenre] { (model.settings.music.autoMix ?? AutoMixSettings())[slot].allGenres }

    /// At least one genre always stays selected.
    private func toggle(_ genre: MusicGenre) {
        var list = selectedGenres
        if let index = list.firstIndex(of: genre) {
            guard list.count > 1 else { return }
            list.remove(at: index)
        } else {
            list.append(genre)
        }
        var mix = model.settings.music.autoMix ?? AutoMixSettings()
        mix[slot].setGenres(list)
        model.settings.music.autoMix = mix
    }

    private func binding<Value>(_ path: WritableKeyPath<AutoMixSlot, Value>) -> Binding<Value> {
        Binding {
            (model.settings.music.autoMix ?? AutoMixSettings())[slot][keyPath: path]
        } set: { value in
            var mix = model.settings.music.autoMix ?? AutoMixSettings()
            mix[slot][keyPath: path] = value
            model.settings.music.autoMix = mix
        }
    }
}

/// Status of the generated playlists, with Connect / Shuffle actions.
struct AutoMixStatusView: View {
    @Environment(AppModel.self) private var model
    @State private var signInError: String?

    var body: some View {
        let builder = model.music.autoMix
        VStack(alignment: .leading, spacing: 8) {
            switch builder.state {
            case .building(let step):
                HStack(spacing: 8) {
                    ProgressView()
                    Text(step).foregroundStyle(Theme.secondaryText)
                }
            case .needsAuthorization:
                Text("Sign in to Spotify once so the app can search songs and create the playlists.").foregroundStyle(Theme.secondaryText)
                Button {
                    Task { signInError = await model.music.signInForAutoMix() }
                } label: {
                    Label("Sign in to Spotify", systemImage: "person.crop.circle.badge.checkmark")
                }
                if let signInError {
                    Text(signInError).font(.caption).foregroundStyle(.orange)
                }
            case .failed(let message):
                Text(message).foregroundStyle(.orange)
                shuffleButton
            case .ready, .idle:
                if let builtAt = builder.builtAt, !builder.selections.isEmpty {
                    Text("Mix ready · \(builtAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(Theme.secondaryText)
                } else {
                    Text("No mix yet.").foregroundStyle(Theme.secondaryText)
                }
                if !builder.missingSlots.isEmpty {
                    Text("Too few fitting songs for: \(builder.missingSlots.map(\.displayName).joined(separator: ", ")). Try another genre or a wider tempo range.")
                        .font(.caption).foregroundStyle(.orange)
                }
                shuffleButton
            }
        }
        .font(.subheadline)
    }

    private var shuffleButton: some View {
        Button {
            model.music.prepareAutoMix(force: true)
        } label: {
            Label("Shuffle new songs", systemImage: "shuffle")
        }
    }
}
