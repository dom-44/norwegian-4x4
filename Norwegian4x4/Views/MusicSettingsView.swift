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

            if prefs.provider == .spotify || prefs.provider == .youtube || prefs.provider == .manual {
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
                Button("Sign out of Spotify", role: .destructive) { spotify.signOut() }
            default:
                Button(spotify.hasToken ? "Reconnect to Spotify" : "Connect Spotify") {
                    spotify.authorizeAndPlay(uri: model.settings.music.warmUp?.uri)
                }
                if spotify.hasToken {
                    Button("Sign out of Spotify", role: .destructive) { spotify.signOut() }
                }
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text("Uses the official Spotify iOS SDK to remote-control the Spotify app. Requires the Spotify app; playing a specific playlist requires Spotify Premium. Connecting briefly opens Spotify and returns here. Spotify must be running for automatic switching; while the phone is locked switching is attempted but not guaranteed by iOS.")
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
