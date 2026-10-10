import FourByFourCore
import SwiftUI

struct ActiveWorkoutView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmEnd = false
    @State private var confirmRestart = false

    private var workout: WorkoutController { model.workout }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let progress = workout.progress {
                if progress.status == .preparing {
                    preparing(progress)
                } else {
                    content(progress)
                }
            }
        }
        .confirmationDialog("End workout?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("Save and end") { workout.end(save: true) }
            Button("Discard workout", role: .destructive) { workout.end(save: false) }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("The workout so far can be saved to your history.")
        }
        .confirmationDialog("Restart the whole workout?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart from warm-up", role: .destructive) { workout.restartWorkout() }
            Button("Cancel", role: .cancel) {}
        }
        .statusBarHidden(false)
    }

    // MARK: Preparing

    private func preparing(_ progress: WorkoutProgress) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Text("Get ready").font(.title.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            Text("\(Int(progress.preparationRemaining.rounded(.up)))")
                .font(.system(size: 160, weight: .heavy, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: Int(progress.preparationRemaining.rounded(.up)))
            if let phase = progress.phase {
                Text("First: \(phase.name) · \(Format.clock(phase.duration))")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.color(for: phase.kind))
            }
            Spacer()
            Button("Cancel", role: .cancel) { workout.end(save: false) }
                .font(.headline)
                .padding(.bottom, 30)
        }
    }

    // MARK: Running / paused

    private func content(_ progress: WorkoutProgress) -> some View {
        let phaseColor = progress.phase.map { Theme.color(for: $0.kind) } ?? Theme.accent
        // Order = what matters while running: where am I, time left, heart
        // rate, then music and controls. The ring is the only flexible element,
        // so everything fits on small phones without scrolling.
        return VStack(spacing: 12) {
            header(progress, color: phaseColor)
            totalProgress(progress)
            banners

            ZStack {
                ProgressRing(fraction: progress.phaseFraction, color: phaseColor, lineWidth: 18)
                VStack(spacing: 4) {
                    Text(Format.countdown(progress.phaseRemaining))
                        .font(.system(size: 80, weight: .heavy, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .accessibilityLabel("\(Format.countdown(progress.phaseRemaining)) remaining in \(progress.phase?.name ?? "phase")")
                    if progress.status == .paused {
                        Text("PAUSED").font(.headline.weight(.heavy)).foregroundStyle(.yellow)
                    } else if let next = progress.nextPhase {
                        Text("then \(next.name)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.color(for: next.kind))
                            .lineLimit(1)
                    } else {
                        Text("last phase").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(28)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 300, maxHeight: 300)
            .frame(maxHeight: .infinity)
            .layoutPriority(-1)
            .id(workout.phaseChangeCount)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .animation(.spring(duration: 0.4), value: workout.phaseChangeCount)

            heartRate
            controls(progress)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// "of 4 intervals" style context for the phase name.
    private func phaseContext(_ phase: PhaseDefinition) -> String {
        let phases = workout.session?.plan.phases ?? []
        let intervals = phases.filter { $0.kind == .interval }.count
        switch phase.kind {
        case .interval: return "of \(intervals) · Go hard"
        case .recovery: return "of \(max(intervals - 1, 1)) · Easy, keep moving"
        case .warmUp: return "Build up gradually"
        case .coolDown: return "Ease down gradually"
        }
    }

    private func header(_ progress: WorkoutProgress, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.phase?.name ?? "")
                    .font(.title.weight(.heavy))
                    .foregroundStyle(color)
                if let phase = progress.phase {
                    Text(phaseContext(phase))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                SensorBadge(state: model.sensor.state, signal: model.sensor.signal())
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder private var banners: some View {
        if workout.restoredFromTermination {
            Label("Workout restored after the app was closed.", systemImage: "arrow.clockwise.circle")
                .font(.footnote)
                .foregroundStyle(.yellow)
        }
        if let prompt = model.music.prompt {
            MusicPromptBanner(prompt: prompt)
        }
        if model.music.providerKind == .spotify, model.music.spotify.status == .connected, model.music.spotify.trackTitle != nil {
            NowPlayingBar()
        }
    }

    private var heartRate: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(workout.signal.liveBPM.map(String.init) ?? "--")
                        .font(.system(size: 64, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(workout.signal.liveBPM == nil ? Theme.secondaryText : Theme.color(for: workout.zone))
                    Text("bpm").font(.title3).foregroundStyle(Theme.secondaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(workout.signal.liveBPM.map { "Heart rate \($0) beats per minute" } ?? "Heart rate unavailable")
                Text(targetLine).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            // Warm-up / cool-down have no target: no badge rather than a
            // meaningless "No target zone".
            if workout.zone != .noTarget {
                ZoneBadge(zone: workout.zone, large: true)
            }
        }
        .card()
    }

    private var targetLine: String {
        var parts: [String] = []
        if let target = workout.target {
            parts.append("Target \(target.label)")
        }
        if let bpm = workout.signal.liveBPM {
            parts.append("\(HeartRateZones.percentOfMax(bpm: bpm, maxHR: workout.maxHeartRate))% HRmax")
        } else if case .noContact = workout.signal {
            parts.append("Check strap contact")
        }
        return parts.joined(separator: " · ")
    }

    private func totalProgress(_ progress: WorkoutProgress) -> some View {
        VStack(spacing: 6) {
            // One segment per phase in its colour: shows where you are in the
            // whole workout and how many intervals are left at a glance.
            PhaseTimeline(phases: workout.session?.plan.phases ?? [],
                          currentIndex: progress.phase?.id ?? 0,
                          phaseFraction: progress.phaseFraction)
            HStack {
                Text(Format.clock(progress.activeElapsed))
                Spacer()
                Text("\(Format.countdown(progress.totalRemaining)) left")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Format.clock(progress.activeElapsed)) elapsed, \(Format.countdown(progress.totalRemaining)) left in the workout")
    }

    private func controls(_ progress: WorkoutProgress) -> some View {
        HStack(spacing: 28) {
            Button { confirmEnd = true } label: {
                Image(systemName: "xmark")
                    .font(.title.weight(.bold))
                    .frame(width: 72, height: 72)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("End workout")

            Button { workout.togglePause() } label: {
                Image(systemName: progress.status == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 96, height: 96)
                    .background(progress.status == .paused ? Color.green : Color.yellow, in: Circle())
            }
            .accessibilityLabel(progress.status == .paused ? "Resume" : "Pause")

            Menu {
                Button { workout.skipPhase() } label: { Label("Skip to next phase", systemImage: "forward.end.fill") }
                Button { workout.restartPhase() } label: { Label("Restart this phase", systemImage: "backward.end.fill") }
                Button(role: .destructive) { confirmRestart = true } label: { Label("Restart workout", systemImage: "arrow.counterclockwise") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title.weight(.bold))
                    .frame(width: 72, height: 72)
                    .background(Color.white.opacity(0.12), in: Circle())
            }
            .accessibilityLabel("More workout controls")
        }
        .foregroundStyle(.white)
        .padding(.bottom, 8)
    }
}

private struct SensorBadge: View {
    var state: SensorConnectionState
    var signal: HeartRateSignal.State

    private var appearance: (icon: String, text: String, color: Color) {
        switch (state, signal) {
        case (.connected, .live): return ("heart.fill", "Live", .green)
        case (.connected, .noContact): return ("hand.raised.fill", "No contact", .yellow)
        case (.connected, _): return ("hourglass", "Waiting", .yellow)
        case (.reconnecting, _), (.connecting, _): return ("antenna.radiowaves.left.and.right", "Reconnecting", .orange)
        default: return ("heart.slash", "No sensor", .gray)
        }
    }

    var body: some View {
        let look = appearance
        Label(look.text, systemImage: look.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(look.color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(look.color.opacity(0.15), in: Capsule())
    }
}

private struct MusicPromptBanner: View {
    @Environment(AppModel.self) private var model
    var prompt: MusicPrompt

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(prompt.selection.map { "Switch to \($0.title.isEmpty ? prompt.slot.displayName : $0.title)" } ?? "Switch to \(prompt.slot.displayName.lowercased()) music")
                    .font(.subheadline.weight(.semibold))
                if let reason = prompt.reason {
                    Text(reason).font(.caption).foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            if prompt.selection != nil, prompt.provider == .spotify || prompt.provider == .youtube {
                Button("Open") { model.music.openSelection(for: prompt.slot) }
                    .font(.subheadline.weight(.bold))
                    .buttonStyle(.borderedProminent)
            }
            Button { model.music.dismissPrompt() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Current Spotify track with previous / restart / next. Large targets so
/// it can be hit while running.
private struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let spotify = model.music.spotify
        // One row: song on the left, controls on the right (44 pt targets).
        HStack(spacing: 8) {
            Image(systemName: spotify.isPaused ? "pause.fill" : "music.note")
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(spotify.trackTitle ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(spotify.trackArtist ?? "").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if model.settings.music.autoMixEnabled {
                let rating = model.music.currentRating
                control("hand.thumbsdown", label: "Don't like: remove song and skip") { model.music.dislikeCurrentTrack() }
                control(rating == .liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                        label: rating == .liked ? "Liked. Tap to undo" : "Like: play more often",
                        tint: rating == .liked ? Theme.accent : nil) { model.music.toggleLikeCurrentTrack() }
            }
            if model.music.canJumpToChorus {
                // Intervals: skip slow intros. The spot is remembered for next time.
                // Tap and hold are separate gestures; on a Button the hold would also fire the tap.
                controlIcon("goforward.15", tint: nil)
                    .contentShape(Circle())
                    .onTapGesture { model.music.jumpForwardInCurrentTrack(); Haptics.tap() }
                    .onLongPressGesture(minimumDuration: 0.6) { model.music.forgetStartOfCurrentTrack(); Haptics.tap() }
                    .accessibilityElement()
                    .accessibilityLabel("Skip 15 seconds ahead; the song starts here next time")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.music.jumpForwardInCurrentTrack() }
                    .accessibilityAction(named: "Back to the beginning and forget the start") { model.music.forgetStartOfCurrentTrack() }
            } else {
                control("arrow.counterclockwise", label: "Play song again from the start") { spotify.perform(.restart) }
            }
            control("forward.end.fill", label: "Next song") { spotify.perform(.next) }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func control(_ symbol: String, label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            controlIcon(symbol, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func controlIcon(_ symbol: String, tint: Color?) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(tint ?? .white)
            .frame(width: 44, height: 44)
            .background((tint ?? .white).opacity(tint == nil ? 0.1 : 0.2), in: Circle())
    }
}
