import SwiftUI

struct MenuBarRecorderView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var isStopConfirmationVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HStack(spacing: 8) {
                    TotalRecActivitySymbol(
                        systemImage: activeStage?.totalRecMenuBarIconName ?? appModel.menuBarIconName,
                        tint: activeStage?.totalRecStatusTint ?? SessionStage.idle.totalRecStatusTint,
                        motion: activeStage?.totalRecActivityMotion ?? .none,
                        size: 15,
                        weight: .bold
                    )
                    Text(appModel.menuBarTitle)
                        .font(.headline)
                }
                Spacer()
                Button("Open Window") {
                    openMainWindow()
                }
                .totalRecGlassButton()
            }

            if let activeStage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(activeStage.totalRecProgressHeadline)
                        .font(.subheadline.weight(.semibold))
                    Text(appModel.statusText)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                    Text(activeStage.totalRecProgressSupportText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .totalRecStaticRoundedRect(cornerRadius: 12, tint: activeStage.totalRecStatusTint)
            } else {
                Text(appModel.revealMainStatus())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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
                        .totalRecGlassButton()

                        Spacer()

                        Button("Stop and Save") {
                            isStopConfirmationVisible = false
                            Task { await appModel.stopRecording() }
                        }
                        .totalRecGlassButton(prominent: true)
                    }
                }
                .padding(10)
                .totalRecGlassRoundedRect(cornerRadius: 10, tint: TotalRecGlass.recordingRed)
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
                            .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .totalRecGlassPanel(cornerRadius: 18)
    }

    @ViewBuilder
    private var actionRow: some View {
        if appModel.isRecording {
            Button("Stop Recording…") {
                isStopConfirmationVisible = true
            }
            .totalRecGlassButton(prominent: true)
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
            .totalRecGlassButton(prominent: true)
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

    private var activeStage: SessionStage? {
        guard let stage = appModel.activeSession?.stage, stage.totalRecShowsLiveActivity else { return nil }
        return stage
    }
}
