import FourByFourCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            HomeView()
        }
        .fullScreenCover(isPresented: workoutCoverBinding) {
            Group {
                if model.workout.isActive {
                    ActiveWorkoutView()
                } else if let record = model.workout.finishedRecord {
                    NavigationStack {
                        WorkoutSummaryView(record: record, isPostWorkout: true)
                    }
                }
            }
            .environment(model)
            .preferredColorScheme(.dark)
        }
    }

    private var workoutCoverBinding: Binding<Bool> {
        Binding(
            get: { model.workout.isActive || model.workout.finishedRecord != nil },
            set: { presented in if !presented { model.workout.dismissSummary() } }
        )
    }
}
