import SwiftUI

struct MenuBarRecorderView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var isStopConfirmationVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Label(appModel.menuBarTitle, systemImage: appModel.menuBarIconName)
                    .font(.headline)
                Spacer()
                Button("Open Window") {
                    openMainWindow()
                }
                .buttonStyle(.borderless)
            }

            Text(appModel.revealMainStatus())
                .font(.footnote)
                .foregroundStyle(.secondary)

            if appModel.isRecording, let startedAt = appModel.recordingStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    LabeledContent("Elapsed") {
                        Text(Self.durationFormatter.string(from: context.date.timeIntervalSince(startedAt)) ?? "0:00")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }

            if isStopConfirmationVisible {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Stop recording and save the session?")
                        .font(.subheadline)
                    Text("This confirms the stop action and keeps the captured audio for transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Keep Recording") {
                            isStopConfirmationVisible = false
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Stop and Save") {
                            isStopConfirmationVisible = false
                            Task { await appModel.stopRecording() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                actionRow
            }

            if let session = appModel.activeSession, session.hasUserData {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.sourceDescription)
                        .font(.subheadline)
                    if let error = session.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private var actionRow: some View {
        if appModel.isRecording {
            Button("Stop Recording…") {
                isStopConfirmationVisible = true
            }
            .buttonStyle(.borderedProminent)
        } else if appModel.hasProtectedActivity {
            Text("Processing is in progress. Use the main window for detailed controls.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button("Start Recording") {
                Task {
                    await appModel.startRecording {
                        openMainWindow()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}
