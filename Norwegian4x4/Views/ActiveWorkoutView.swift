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
                Text("First: \(phase.name) · \(Format.clock(phase.duration))").font(.title3)
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
        return VStack(spacing: 14) {
            header(progress, color: phaseColor)
            banners

            ZStack {
                ProgressRing(fraction: progress.phaseFraction, color: phaseColor, lineWidth: 20)
                VStack(spacing: 2) {
                    Text(Format.countdown(progress.phaseRemaining))
                        .font(.system(size: 76, weight: .heavy, design: .rounded).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .accessibilityLabel("\(Format.countdown(progress.phaseRemaining)) remaining in \(progress.phase?.name ?? "phase")")
                    Text(progress.status == .paused ? "PAUSED" : "remaining")
                        .font(.headline)
                        .foregroundStyle(progress.status == .paused ? Color.yellow : Theme.secondaryText)
                }
                .padding(30)
            }
            .frame(maxWidth: 300, maxHeight: 300)
            .padding(.horizontal, 24)
            .id(workout.phaseChangeCount)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .animation(.spring(duration: 0.4), value: workout.phaseChangeCount)

            heartRate
            totalProgress(progress)
            if let next = progress.nextPhase {
                Text("Next: \(next.name) · \(Format.clock(next.duration))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("Last phase").font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            controls(progress)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func header(_ progress: WorkoutProgress, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.phase?.name ?? "")
                    .font(.title.weight(.heavy))
                    .foregroundStyle(color)
                if let phase = progress.phase {
                    Text("Phase \(phase.id + 1) of \(workout.session?.plan.phases.count ?? 0) · \(phase.kind.displayName)")
                        .font(.subheadline)
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
            ZoneBadge(zone: workout.zone, large: true)
        }
        .card()
    }

    private var targetLine: String {
        var parts: [String] = []
        if let target = workout.target {
            parts.append("Target \(target.label)")
        } else if let phase = workout.progress?.phase {
            parts.append(phase.kind == .warmUp ? "Build up gradually" : "Ease down gradually")
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
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: geo.size.width * min(1, max(0, progress.totalFraction)))
                }
            }
            .frame(height: 8)
            HStack {
                Text("Elapsed \(Format.clock(progress.activeElapsed))")
                Spacer()
                Text("\(Format.percent(progress.totalFraction))")
                Spacer()
                Text("Left \(Format.countdown(progress.totalRemaining))")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .combine)
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
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: spotify.isPaused ? "pause.circle" : "music.note").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(spotify.trackTitle ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(spotify.trackArtist ?? "").font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            HStack {
                control("backward.end.fill", label: "Previous song") { spotify.perform(.previous) }
                control("arrow.counterclockwise", label: "Play song again from the start") { spotify.perform(.restart) }
                control("forward.end.fill", label: "Next song") { spotify.perform(.next) }
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.tap()
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }
}
