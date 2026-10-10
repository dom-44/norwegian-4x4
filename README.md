# Norwegian 4x4 — iOS interval trainer

A personal iPhone app for Norwegian 4x4 interval training with live heart rate
from a **Polar H10** (or any standard Bluetooth LE heart-rate strap), voice
coaching, and music via **Spotify** (official SDK), **YouTube** (official apps)
or **manual** mode. Native Swift / SwiftUI, no backend, no accounts, no analytics.

- **Deployment target:** iOS 17.0 (needed for the Observation framework,
  `ContentUnavailableView`, and current Swift Charts / SwiftUI APIs).
- **Xcode:** 16 or newer (the project uses Xcode 16 "synchronized folders").
- **Dependencies:** `FourByFourCore` (local Swift package in this repo) and the
  official Spotify iOS SDK (Swift Package, optional — the app builds and runs
  without it, Spotify is then shown as unavailable).

---

## 1. Project layout

```
Norwegian4x4.xcodeproj           Xcode project + shared scheme
Config/
  Base.xcconfig                  build settings (placeholders)
  Secrets.example.xcconfig       copy to Secrets.xcconfig (git-ignored)
  Info.plist                     permissions, background modes, URL scheme
Norwegian4x4/                    iOS app (SwiftUI, Core Bluetooth, AVFoundation)
  App/          AppModel (composition root), @main
  Bluetooth/    HeartRateSensorManager — Core Bluetooth HR client
  Workout/      WorkoutController — runs a session on the main actor
  Audio/        CoachingAudio (speech + generated tones), Haptics
  Music/        Spotify / YouTube providers, MusicCenter
  Support/      Keychain, lock-screen backup alerts
  Views/        Home, Sensor setup, Pre-workout, Active workout, Summary,
                History, Settings, Music settings
Packages/FourByFourCore/         platform-independent logic + unit tests
  WorkoutEngine.swift            state machine & timer (timestamp based)
  WorkoutSession.swift           engine + HR recording + crash-safe persistence
  HeartRateMeasurement.swift     0x2A37 packet parser
  HeartRateZones.swift           HRmax, zones, rounding rule, stale detection
  WorkoutStatistics.swift        averages, time in zone, gaps, per-interval stats
  Music.swift / MusicLink.swift  provider protocol, coordinator, link parsing
  Coaching.swift                 coaching lines and cue settings
  Persistence.swift              JSON stores (settings, active session, history)
```

The workout engine knows nothing about Bluetooth, audio, UI or music. Music
providers sit behind the `MusicProvider` protocol and are only called by the
`MusicCoordinator`, which never throws and never blocks the timer.

---

## 2a. Building without a Mac (Windows)

Apple's iOS SDK and Xcode only run on macOS, so on Windows the app cannot be
compiled locally. Two ways around that:

### Route A — GitHub Actions + sideloading with a free Apple ID (no cost)

1. Push this folder to a GitHub repository. A **public** repo gets free macOS
   build minutes. In a **private** repo macOS minutes count 10× against the
   free 2,000-minute quota (≈ 200 macOS minutes/month, roughly 10–15 builds).
2. Optional, in the repository's *Settings › Secrets and variables › Actions*:
   - secret `SPOTIFY_CLIENT_ID` (see §5),
   - variable `APP_BUNDLE_ID`, e.g. `com.yourname.norwegian4x4` (must be unique
     to you and match the Spotify dashboard).
3. *Actions › iOS build & test › Run workflow* (it also runs on every push).
   The workflow (`.github/workflows/ios.yml`) runs `swift test` on the core
   package and the unit tests on an iOS Simulator, builds a Release app for
   iPhone, and uploads **`Norwegian4x4-unsigned-ipa`** as an artifact.
4. On Windows install **iTunes** and **iCloud** from apple.com (the
   non-Microsoft-Store installers), then a sideloading tool such as
   **Sideloadly** (sideloadly.io) or **AltStore** (altstore.io). These are
   third-party tools that sign the app with *your* Apple ID through Apple's
   free developer provisioning. You type your Apple ID password into them, so
   only proceed if you trust them. A separate Apple ID just for this also works.
5. Connect the iPhone by USB and tap *Trust*. Drop the unzipped `.ipa` into
   Sideloadly, enter your Apple ID and press *Start*.
6. On the iPhone: *Settings › General › VPN & Device Management* › trust your
   Apple ID; enable *Settings › Privacy & Security › Developer Mode* when asked.

Limits of free signing: the app stops launching after **7 days** and needs to
be signed and installed again from Sideloadly. Re-signing keeps your data if
the bundle ID stays the same. You can have at most 3 sideloaded apps. All features this app uses (Bluetooth,
background modes, local notifications, Keychain) work with free signing.

### Route B — paid Apple Developer Program ($99/year)

With a paid membership the CI job can sign and upload to **TestFlight**, and
you install from the TestFlight app (90-day builds, no 7-day re-signing). That
requires an App Store Connect API key stored as repository secrets and an
extra signing/export step; it is not set up in this repo yet.

(A rented cloud Mac also works: follow §2 there, then sideload the `.ipa` as in
Route A.)

## 2. Requirements & first build (with a Mac)

1. A Mac with **macOS 14.5+** and **Xcode 16+** (App Store).
2. Sign in to Xcode with your Apple ID: *Xcode › Settings › Accounts › +*.
   A free "Personal Team" works — no paid membership is needed for any
   capability this app uses (Bluetooth, background modes, notifications,
   Keychain). With a free team, the app must be re-installed from Xcode every
   7 days.
3. Configure your local secrets:
   ```sh
   cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
   ```
   Edit `Config/Secrets.xcconfig`:
   - `DEVELOPMENT_TEAM` – your Team ID (shown in *Accounts › Manage Certificates*
     or in the Signing tab once selected).
   - `APP_BUNDLE_ID` – something unique, e.g. `com.yourname.norwegian4x4`.
   - `SPOTIFY_CLIENT_ID` – optional, see §5.
4. Open `Norwegian4x4.xcodeproj`. Xcode resolves the Swift packages
   automatically (*File › Packages › Resolve Package Versions* if not).
5. Signing: select the **Norwegian4x4** target › *Signing & Capabilities*,
   keep *Automatically manage signing* on and pick your team (if not taken from
   the xcconfig).
6. Connect your iPhone by cable (first time), unlock it, tap *Trust*.
   On the iPhone enable **Settings › Privacy & Security › Developer Mode**
   (requires a restart).
7. Choose your iPhone as the run destination in the toolbar and press **⌘R**.
   First run with a free team: on the iPhone open *Settings › General › VPN &
   Device Management*, trust your developer certificate, then launch again.

### Info.plist, background modes and capabilities

All of these are already configured (`Config/Info.plist` and build settings):

| Key | Value | Why |
|---|---|---|
| `NSBluetoothAlwaysUsageDescription` | text | Required to use Core Bluetooth |
| `UIBackgroundModes` | `bluetooth-central` | Keep receiving HR notifications while locked / in another app |
| `UIBackgroundModes` | `audio` | Speak coaching cues and play transition tones while locked |
| `CFBundleURLTypes` | scheme `norwegian4x4` | Spotify authorization redirect |
| `LSApplicationQueriesSchemes` | `spotify`, `youtube`, `youtubemusic` | Detect installed apps |
| `SpotifyClientID` | `$(SPOTIFY_CLIENT_ID)` | From your xcconfig |
| `SpotifyRedirectURI` | `norwegian4x4://spotify-login-callback` | Must match the Spotify dashboard |
| `UIUserInterfaceStyle` | Dark | Workout-first dark UI |
| `OTHER_LDFLAGS` | `-ObjC` | Required by the Spotify SDK |

No entitlements file is needed. Permissions requested: Bluetooth (when you
open sensor setup) and notifications (when you start a workout with
lock-screen alerts enabled). Nothing else.

---

## 3. Polar H10 setup

1. Moisten the electrode areas of the strap, snap on the H10 and wear it. The
   H10 only advertises while it detects skin contact.
2. **Do not** pair it in iOS Settings › Bluetooth. Close Polar Flow / Polar Beat
   if they are running (the H10 accepts a limited number of connections).
3. In the app: *Home › sensor card* (or *Settings › Heart rate sensor*). The
   app scans for the standard Heart Rate Service (0x180D); devices named
   "Polar H10 …" are highlighted and listed first.
4. Tap your sensor. Live BPM, RR-interval, signal strength and battery (Battery
   Service 0x180F, if offered) are shown. The sensor is remembered and
   reconnected automatically on the next launch.

Implementation notes:

- Subscribes to Heart Rate Measurement (0x2A37) notifications and parses flags,
  8/16-bit values, sensor-contact bits, energy expended and RR-intervals.
- A reading older than **5 s**, or a packet reporting lost skin contact, is
  *never* shown as current — the UI shows "--" / "No heart rate" instead.
- Connection loss → a pending `connect()` is queued; iOS completes it
  automatically (also in the background) when the strap is back in range.
  Failed attempts back off exponentially up to 30 s. A **Reconnect** button is
  always available.
- Core Bluetooth **state restoration** is enabled (restore identifier
  `Norwegian4x4.central`) so iOS can relaunch the app for BLE events.
- Bluetooth turned off → state shown, reconnects when it is turned back on.
- The workout timer never depends on the sensor; HR is recorded only while
  the workout clock runs, and gaps are reported in the summary.

---

## 4. Workout protocol and timer semantics

Default (restorable with one tap in Settings): 10 min warm-up, 4 × (4 min at
85–95 % HRmax, 3 min active recovery at 60–70 %; no recovery after the last
interval), 5 min cool-down = **40 min**. Warm-up, interval, recovery, cool-down
durations and interval count (1–8) are configurable.

**State machine:** `idle → preparing (5 s countdown) → running ⇄ paused →
completed | cancelled`. Phase transitions are emitted exactly once as events.

**Timing:** no tick counting. The engine stores *timestamps* (a monotonic clock
that keeps counting during device sleep — `CLOCK_MONOTONIC` — plus the wall
clock and a boot ID) and derives everything (current phase, remaining time,
progress) from them. Across a reboot it falls back to the wall clock.

- **Pause:** workout time stops; the sensor stays connected (readings are not
  recorded while paused).
- **Skip:** jumps to the start of the next phase (from the last phase it
  completes the workout). *Elapsed* shows real training time; the timeline
  position (and therefore progress) jumps.
- **Restart phase:** back to the start of the current phase; its cues fire again.
- **Restart workout:** discards progress and samples, starts from preparation.
- **End:** asks for confirmation; you can save the partial workout or discard it.

**Background / termination recovery:** the session snapshot is written to disk
on every state change (and heart-rate samples every 15 readings and on
backgrounding). When the app resumes or is relaunched it recomputes the phase
from the timestamps. Delivered cues are recorded in the snapshot, so nothing is
announced twice. If phases passed while the app was suspended they are marked
as such (no stale announcements); the current phase gets one short catch-up
announcement ("Recovery 2. 1 minute 30 seconds remaining.").

---

## 5. Spotify (official iOS SDK)

The app uses the official **Spotify iOS SDK (App Remote)** —
https://github.com/spotify/ios-sdk — added as a Swift Package. It remote-controls
the installed Spotify app; audio is played by Spotify itself. Nothing is
streamed or extracted.

### Dashboard setup (one time)

1. Go to https://developer.spotify.com/dashboard › *Create app*.
2. **Redirect URI:** `norwegian4x4://spotify-login-callback` (exactly).
3. APIs used: tick **iOS**. Add your **bundle ID** (the `APP_BUNDLE_ID` you
   chose) under the iOS settings.
4. While the app is in *Development mode*, add your Spotify account e-mail under
   *User Management*.
5. Copy the **Client ID** into `Config/Secrets.xcconfig` as `SPOTIFY_CLIENT_ID`.
   No client secret is needed or used — never put one in the project.

### Using it

- *Music › Spotify › Connect Spotify* opens Spotify for authorization (and
  starts your warm-up playlist), then returns to the app. The access token is
  stored in the **Keychain** and never logged.
- Per phase (warm-up, intervals, recovery, cool-down) paste a playlist/album
  share link (`https://open.spotify.com/playlist/…` or `spotify:playlist:…`).
- At each phase change the app asks Spotify to play the matching playlist.

### Pick songs by genre (auto mix)

*Music › Pick songs by genre* replaces the links with a **genre and tempo range
per phase** (defaults: warm-up 110–130 BPM, intervals 145–175, recovery 100–125,
cool-down 70–100). When the pre-workout screen opens (or on *Shuffle new
songs*) the app:

1. searches Spotify for ~60 tracks per genre (Web API `GET /search`, 10 per
   page — the Development Mode limit since February 2026), from a random start
   page so each workout differs;
2. looks up tempo and energy at **ReccoBeats** (`api.reccobeats.com`, free, no
   key) because Spotify's own audio-features endpoint is closed to apps created
   after November 2024; half/double-time readings are accepted;
3. keeps the fitting tracks (max 2 per artist, each track used once) and writes
   them into four private playlists, `4x4 · Warm-up` etc., in your account
   (`POST /me/playlists`, `PUT /playlists/{id}/items`). They are reused and
   refilled; deleting them is harmless.

Repeated intervals start two tracks further into the interval playlist, so
each interval begins with a new song. The App Remote token only allows remote
control (the Web API answers "Insufficient client scope"), so the mix signs in
separately: *Sign in to Spotify* opens Spotify's web login (Authorization Code
with PKCE, no client secret, scopes `playlist-modify-private` and
`playlist-read-private`). The refresh token is kept in the Keychain, so this is
needed only once. If anything fails (no network, ReccoBeats down, too few fitting
songs) the previous mix or your own links are used; the workout is never
affected. Pure logic (`AutoMix.swift`) is unit-tested; the network calls are
not.

#### Researched song lists and ratings

Every phase draws from researched lists (`CuratedCatalog+Data.swift`) for
EDM, Drum & Bass, Trance, Hard Rock and Punk Rock: high-energy songs for the
intervals, mid-energy for warm-up and recovery, calm ones for the cool-down.
Each song was resolved to its Spotify ID and checked for tempo and energy via
ReccoBeats (sources and scripts: `scripts/curate/`). Several genres per phase
are mixed evenly.

On the workout screen 👍 makes a song three times as likely to be picked in
future mixes; 👎 skips it, removes it from the `4x4 ·` playlists and excludes
it from now on. Ratings are stored on the device (*Music › Your ratings*).

During intervals ⏩ skips 15 s ahead and remembers the spot: the next time the
song plays in an interval, the app seeks straight there (only if the song is
still within its first 5 s, so manual rewinds aren't overridden). Holding ⏩
goes back to 0 and forgets the start point. Spotify no longer gives new apps
song sections (audio analysis), so the fast part can't be found automatically.

### What is and isn't supported

| Feature | Status |
|---|---|
| Authorize, connect to installed Spotify | ✅ (user tap; switches to Spotify briefly) |
| Play a playlist / album URI | ✅ needs **Spotify Premium** for on-demand playback |
| Pause / resume with workout pause | ✅ when connected |
| Read now-playing / paused state | ✅ when connected |
| Automatic switching with the screen locked | ⚠️ attempted; works only while this app is running in the background (it normally is, because the H10 keeps it alive) **and** the App Remote connection is still alive. Not guaranteed by iOS. |
| Connecting when Spotify is not running | ❌ App Remote requires Spotify to be running; the app never opens Spotify by itself — tap *Play warm-up music* on the pre-workout screen before starting |
| Token refresh | ❌ App Remote tokens last ~1 h; reconnect from Music settings when prompted |

Failures fall back to a spoken prompt ("Switch music to Power Mix") and an
**Open** button on the workout screen. After 3 consecutive failures automatic
switching is suspended for the rest of the workout (no reconnect storms, no
repeated authorization screens). A music failure never affects the timer.

If the Spotify package can't be resolved, remove it under *Project › Package
Dependencies*; all Spotify code is behind `#if canImport(SpotifyiOS)` and the app
still builds.

## 5b. Apple Health

*Settings › Apple Health › Save workouts to Apple Health* asks for permission
and then saves every finished workout (completed or ended early with data) as a
workout of the chosen type — default *High Intensity Interval Training* —
with the strap's heart rate (one point per 5 s) and, when weight, date of birth
and sex are set in Health, active energy estimated from heart rate (Keytel et
al. 2005). The app reads nothing else from Health.

HealthKit is one of the capabilities Apple allows for free Apple IDs. The CI
build ad-hoc signs the app with `Config/Norwegian4x4.entitlements` so the
HealthKit entitlement is inside the IPA for AltStore / Sideloadly to carry
over when they re-sign it. If the summary screen says the workout was not
saved, check *Settings › Health › Data Access & Devices › 4x4*.

---

## 6. YouTube

There is **no official iOS API to control playback in the YouTube or YouTube
Music apps**. The official embeddable player (IFrame Player API in a web view)
must remain visible and stops when the app is backgrounded or the screen
locks, which makes it unsuitable for workout music. Therefore:

- Select a YouTube / YouTube Music link per phase (Share › Copy link).
- *Open warm-up music in YouTube* on the pre-workout screen opens it in the
  official app via a universal link.
- At phase changes you get a spoken prompt plus an **Open** button that opens the
  right playlist; return to the workout with the iOS back gesture or app
  switcher — the timer is unaffected.
- Whether YouTube keeps playing with the screen locked depends on your YouTube
  Premium subscription. The app does not extract audio, skip ads or bypass
  restrictions.

**Manual mode** (always available): play anything in any app; the app announces
when to switch.

---

## 7. Background behaviour and known iOS limitations

- **With the H10 connected** (normal case) iOS delivers a BLE notification about
  once per second, which keeps the app running in the background. Each one
  advances the state machine, so voice cues, tones and Spotify switching work
  while the phone is locked or another app is in front.
- **Without a sensor** iOS suspends the app shortly after it leaves the
  foreground. The timer is still correct when you return (it is computed from
  timestamps), and **lock-screen alerts** (local notifications, scheduled when
  the app goes to the background) announce phase changes. Spoken cues cannot
  play while suspended.
- The app does **not** play silent audio or use other tricks to stay alive; the
  `audio` background mode is used only to speak cues while running.
- Audio: cues duck other audio (Spotify/YouTube) and restore it afterwards.
  Phone calls / Siri interrupt cues (the timer continues). Unplugging
  headphones cuts the current sentence.
- With the app alive in the background *and* lock-screen alerts on, you may
  hear both the voice cue and the notification sound for a phase change.
  Turn off lock-screen alerts if you always use the sensor.
- Haptics only play while the app is in the foreground (iOS rule).
- The screen is kept awake during workouts (setting) and restored afterwards.
- iOS may still terminate the app under memory pressure; the session is then
  restored on next launch (or when iOS relaunches it for a Bluetooth event).

---

## 8. Heart-rate zones

- HRmax: manual, or estimated as **220 − age** (labelled as an estimate).
- Intervals: 85–95 % HRmax. Recovery: 60–70 %. Warm-up / cool-down: no target.
- Rounding rule (everywhere): each bound = percent × HRmax / 100 rounded to the
  nearest bpm, halves up, integer arithmetic. "In target" means
  `lower ≤ bpm ≤ upper`. E.g. HRmax 185 → intervals 157–176, recovery 111–130.
- Zone feedback uses colour **and** icon **and** text: below / in / above target,
  no heart rate.
- These are training estimates, not medical advice.

---

## 9. Data & privacy

- Everything is stored as JSON in the app's Application Support folder on the
  iPhone (file protection: *complete until first unlock*, so it can be written
  while locked). Spotify token: Keychain (`AfterFirstUnlockThisDeviceOnly`).
- No network calls except those made by the Spotify SDK to the Spotify app.
- *Settings › Data*: delete all workouts, reset settings. Swipe to delete
  single workouts in History.

---

## 10. Tests

The logic lives in `Packages/FourByFourCore` and has XCTest coverage for:

standard 40-min configuration · phase order & exact durations · exact
transition times · pause/resume · skip (running/paused/last phase) · restart
phase/workout · cancel · cue scheduling & duplicate prevention · background gap
reconstruction · recovery after simulated termination (same boot and after a
reboot) · paused-session restore · session finished while terminated · HR packet
parsing (8/16-bit, contact, energy, RR, malformed) · battery parsing · zone
calculation & rounding · stale / no-contact detection · statistics (time in
zone, gaps, recovery drop, trends) · music coordinator failures, back-off and
suspension · music failure not affecting the timer · link parsing ·
persistence round-trips.

Run them:

```sh
# Fast, no simulator needed (macOS):
cd Packages/FourByFourCore && swift test

# Or in Xcode: select an iPhone simulator and press ⌘U (the shared scheme
# includes the FourByFourCoreTests bundle).
xcodebuild test -project Norwegian4x4.xcodeproj -scheme Norwegian4x4 \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

On Windows, the core tests also run with the Swift toolchain for Windows
(`winget install Swift.Toolchain`, plus Visual Studio Build Tools with the C++
workload). Run them from an *x64 Native Tools* command prompt, with `SDKROOT`
pointing to `%LOCALAPPDATA%\Programs\Swift\Platforms\<version>\Windows.platform\Developer\SDKs\Windows.sdk\`:
`cd Packages\FourByFourCore && swift test`.

Without a Mac, the GitHub Actions workflow runs both of these on every push
(see §2a); check the *Actions* tab for results and logs.

Things that require real hardware and must be checked by hand on the iPhone:
Polar H10 discovery/connection/reconnection, background BLE delivery while
locked, spoken cues while locked, Spotify authorization and playback control,
opening YouTube links. See the checklist below.

### On-device checklist

1. Sensor setup: H10 appears, connects, shows BPM and battery.
2. Take the strap off → "No contact"/"--" within ~5 s; put back → live again.
3. Walk out of range → "Reconnecting"; come back → reconnects by itself.
4. Start a workout, lock the phone: voice cue at the next phase change.
5. Pause, wait, resume: remaining time unchanged across the pause.
6. Force-quit mid-workout, relaunch: same phase and remaining time, "restored" banner.
7. Spotify: connect, start workout, verify playlist changes at an interval start.

---

## 11. Troubleshooting

| Problem | Fix |
|---|---|
| "No account for team" / signing errors | Select your team in *Signing & Capabilities*; make `APP_BUNDLE_ID` unique |
| App won't open on iPhone ("Untrusted Developer") | *Settings › General › VPN & Device Management* › trust |
| H10 not found | Wear & moisten strap; close Polar apps; replace CR2025 battery; check Bluetooth permission |
| HR shows "--" while connected | Skin contact lost or no packets for 5 s — moisten electrodes, tighten strap |
| Spotify "Could not reach Spotify" | Open Spotify and start any song, then tap Connect/Play again |
| Spotify "not configured" | Set `SPOTIFY_CLIENT_ID` in `Config/Secrets.xcconfig`, clean build (⇧⌘K) |
| Spotify authorization error | Redirect URI and bundle ID in the dashboard must match exactly; add your account under User Management |
| Package resolution fails | *File › Packages › Reset Package Caches*; or remove the Spotify package (app still builds) |
| No voice while locked | Check the ringer volume (media volume), coaching toggles, and that the sensor is connected (keeps the app running) |
