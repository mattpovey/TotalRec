import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum TranscriptSegmentBrowserMode {
    case textEditing
    case speakerEditing
}

struct TranscriptSegmentBrowserPlaybackState {
    let canPlaySelectedSegment: Bool
    let isPlaying: Bool
    let audioAvailable: Bool
    let playClip: () -> Void
    let playWithContext: () -> Void
    let stopPlayback: () -> Void
}

struct TranscriptSegmentBrowser<InlineInspector: View>: View {
    let title: String
    let subtitle: String
    let emptyMessage: String
    let transcript: TranscriptState
    let segments: [TranscriptSegment]
    let mode: TranscriptSegmentBrowserMode
    let audioURL: URL?
    let audioDuration: TimeInterval?
    let emphasizedSpeakerLabel: String?
    @ViewBuilder let inlineInspector: (TranscriptSegment, TranscriptSegmentBrowserPlaybackState) -> InlineInspector

    @StateObject private var playbackController = TranscriptPlaybackController()

    var body: some View {
        TranscriptSegmentBrowserPanel(title: title, subtitle: subtitle) {
            if segments.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(segments) { segment in
                                Button {
                                    handleSelection(segment)
                                } label: {
                                    TranscriptSegmentRow(
                                        segment: segment,
                                        speakerDisplay: transcript.hasSpeakerLabels ? transcriptSpeakerDisplay(for: segment, in: transcript) : nil,
                                        isSelected: playbackController.selectedSegmentID == segment.id,
                                        isActive: playbackController.activeSegmentID == segment.id,
                                        isEmphasized: isSegmentEmphasized(segment)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(segment.id)

                                if playbackController.selectedSegmentID == segment.id {
                                    inlineInspector(
                                        segment,
                                        TranscriptSegmentBrowserPlaybackState(
                                            canPlaySelectedSegment: playbackController.canPlaySelectedSegment,
                                            isPlaying: playbackController.isPlaying,
                                            audioAvailable: audioURL != nil,
                                            playClip: playbackController.playSelectedClip,
                                            playWithContext: playbackController.playSelectedClipWithContext,
                                            stopPlayback: playbackController.pause
                                        )
                                    )
                                    .id(inspectorAnchorID(for: segment.id))
                                }
                            }
                        }
                    }
                    .frame(minHeight: 420)
                    .onChange(of: playbackController.selectedSegmentID) { _, newValue in
                        guard let newValue else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(inspectorAnchorID(for: newValue), anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 460, maxWidth: .infinity, alignment: .topLeading)
        .onAppear(perform: updatePlaybackSession)
        .onChange(of: audioURL) { _, _ in
            updatePlaybackSession()
        }
        .onChange(of: audioDuration) { _, _ in
            updatePlaybackSession()
        }
        .onChange(of: transcript) { _, _ in
            updatePlaybackSession()
        }
        .onChange(of: visibleSegmentIDs) { _, newValue in
            guard let selectedSegmentID = playbackController.selectedSegmentID else { return }
            guard !newValue.contains(selectedSegmentID) else { return }
            playbackController.stopAndClearSelection()
        }
        .onDisappear {
            playbackController.stopAndClearSelection()
        }
    }

    private var visibleSegmentIDs: [UUID] {
        segments.map(\.id)
    }

    private func inspectorAnchorID(for segmentID: UUID) -> String {
        "segment-inspector-\(segmentID.uuidString)"
    }

    private func updatePlaybackSession() {
        playbackController.updateSession(audioURL: audioURL, audioDuration: audioDuration, transcript: transcript)
    }

    private func handleSelection(_ segment: TranscriptSegment) {
        if playbackController.isPlaying, playbackController.activeSegmentID == segment.id {
            playbackController.pause()
            playbackController.selectSegment(segment.id)
            return
        }

        guard segment.start != nil, audioURL != nil else {
            playbackController.selectSegment(segment.id)
            return
        }

        playbackController.selectAndPlay(segmentID: segment.id)
    }

    private func isSegmentEmphasized(_ segment: TranscriptSegment) -> Bool {
        guard mode == .speakerEditing, let emphasizedSpeakerLabel else { return true }
        return transcriptSegmentMatchesSpeakerLabel(segment, label: emphasizedSpeakerLabel)
    }
}

func transcriptSpeakerDisplay(for segment: TranscriptSegment, in transcript: TranscriptState) -> String {
    guard let label = TranscriptState.canonicalSpeakerLabel(segment.speakerLabel) else {
        return "Unassigned"
    }
    let alias = transcript.alias(for: label)
    if alias == label {
        return alias
    }
    return "\(alias) (\(label))"
}

func transcriptTimestampText(for segment: TranscriptSegment) -> String {
    let startText = segment.start.map(formatTranscriptTimestamp) ?? "Untimed"
    if let end = segment.end {
        return "\(startText) - \(formatTranscriptTimestamp(end))"
    }
    return startText
}

func transcriptSegmentMatchesSpeakerLabel(_ segment: TranscriptSegment, label: String?) -> Bool {
    TranscriptState.canonicalSpeakerLabel(segment.speakerLabel) == label
}

func formatTranscriptTimestamp(_ time: TimeInterval) -> String {
    let total = max(Int(time.rounded()), 0)
    let minutes = total / 60
    let seconds = total % 60
    return String(format: "%d:%02d", minutes, seconds)
}

struct TranscriptSegmentDetailBlock: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .totalRecStaticRoundedRect(cornerRadius: 12)
    }
}

private struct TranscriptSegmentRow: View {
    let segment: TranscriptSegment
    let speakerDisplay: String?
    let isSelected: Bool
    let isActive: Bool
    let isEmphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(transcriptTimestampText(for: segment))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if isActive {
                    Label("Playing · Click Again To Stop", systemImage: "speaker.wave.2.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.successGreen))
                } else if segment.start == nil {
                    Label("No timing", systemImage: "clock.badge.xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TotalRecGlass.accentForeground(TotalRecGlass.warningAmber))
                }
            }

            if let speakerDisplay {
                HStack(alignment: .firstTextBaseline) {
                    Text(speakerDisplay)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
            }

            Text(segment.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .opacity(isEmphasized ? 1 : 0.66)
    }

    private var backgroundColor: Color {
        if isActive {
            return TotalRecGlass.successGreen.opacity(0.10)
        }
        if isSelected {
            return Color.accentColor.opacity(0.10)
        }
        return TranscriptSegmentBrowserColors.segmentBackground
    }

    private var borderColor: Color {
        if isActive {
            return TotalRecGlass.successGreen.opacity(0.28)
        }
        if isSelected {
            return Color.accentColor.opacity(0.35)
        }
        return TranscriptSegmentBrowserColors.segmentBorder
    }
}

private struct TranscriptSegmentBrowserPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .totalRecStaticPanel(cornerRadius: 16)
    }
}

struct TranscriptPlaybackControls: View {
    let canPlaySelectedSegment: Bool
    let isPlaying: Bool
    let onPlayClip: () -> Void
    let onPlayWithContext: () -> Void
    let onStopPlayback: () -> Void

    var body: some View {
        Group {
            TranscriptPlaybackTransportButton(
                tooltip: "Play the selected clip only.",
                backgroundColor: TranscriptSegmentBrowserColors.playButtonBackground,
                symbolColor: TranscriptSegmentBrowserColors.playButtonSymbol,
                isEnabled: canPlaySelectedSegment,
                action: onPlayClip
            ) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
            }

            TranscriptContextPlaybackButton(
                backgroundColor: TranscriptSegmentBrowserColors.playButtonBackground,
                symbolColor: TranscriptSegmentBrowserColors.playButtonSymbol,
                isEnabled: canPlaySelectedSegment,
                action: onPlayWithContext
            )

            TranscriptPlaybackTransportButton(
                tooltip: "Stop playback and keep this segment selected.",
                backgroundColor: TranscriptSegmentBrowserColors.stopButtonBackground,
                symbolColor: TranscriptSegmentBrowserColors.stopButtonSymbol,
                isEnabled: isPlaying,
                action: onStopPlayback
            ) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .black))
            }
        }
    }
}

private struct TranscriptPlaybackTransportButton<Label: View>: View {
    let tooltip: String
    let backgroundColor: Color
    let symbolColor: Color
    let isEnabled: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(symbolColor)
                .frame(minWidth: 34, minHeight: 28)
                .padding(.horizontal, 8)
        }
        .totalRecGlassButton(tint: backgroundColor)
        .disabled(!isEnabled)
        .accessibilityLabel(tooltip)
        .opacity(isEnabled ? 1 : 0.45)
        .overlay(alignment: .top) {
            if isHovered {
                TranscriptPlaybackTooltipBubble(text: tooltip)
                    .offset(y: -42)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .zIndex(isHovered ? 10 : 0)
    }
}

private struct TranscriptContextPlaybackButton: View {
    let backgroundColor: Color
    let symbolColor: Color
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var isHoveringPlayGlyph = false
    @State private var isHoveringEllipsis = false

    private var tooltip: String? {
        if isHoveringPlayGlyph {
            return "Play the selected clip."
        }
        if isHoveringEllipsis {
            return "Include a little audio before and after the selected clip."
        }
        if isHovered {
            return "Play the selected clip with surrounding context."
        }
        return nil
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .onHover { hovering in
                        isHoveringPlayGlyph = hovering
                    }
                Text("...")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .baselineOffset(1)
                    .onHover { hovering in
                        isHoveringEllipsis = hovering
                    }
            }
            .foregroundStyle(symbolColor)
            .frame(minWidth: 34, minHeight: 28)
            .padding(.horizontal, 8)
        }
        .totalRecGlassButton(tint: backgroundColor)
        .disabled(!isEnabled)
        .accessibilityLabel("Play the selected clip with surrounding context.")
        .opacity(isEnabled ? 1 : 0.45)
        .overlay(alignment: .top) {
            if let tooltip {
                TranscriptPlaybackTooltipBubble(text: tooltip)
                    .offset(y: -42)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if !hovering {
                isHoveringPlayGlyph = false
                isHoveringEllipsis = false
            }
        }
        .zIndex(tooltip == nil ? 0 : 10)
    }
}

private struct TranscriptPlaybackTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .totalRecGlassRoundedRect(cornerRadius: 8)
            .fixedSize()
            .allowsHitTesting(false)
    }
}

private enum TranscriptSegmentBrowserColors {
    #if os(macOS)
    static let panelBackground = Color(nsColor: .controlBackgroundColor)
    static let panelBorder = Color(nsColor: .separatorColor).opacity(0.85)
    static let segmentBackground = Color(nsColor: .textBackgroundColor)
    static let segmentBorder = Color(nsColor: .separatorColor).opacity(0.68)
    static let detailBackground = Color(nsColor: .textBackgroundColor)
    static let detailBorder = Color(nsColor: .separatorColor).opacity(0.72)
    static let selectionStripBackground = Color(nsColor: .windowBackgroundColor)
    static let selectionStripBorder = Color(nsColor: .separatorColor).opacity(0.8)
    #elseif os(iOS)
    static let panelBackground = Color(uiColor: .secondarySystemBackground)
    static let panelBorder = Color(uiColor: .separator).opacity(0.6)
    static let segmentBackground = Color(uiColor: .systemBackground)
    static let segmentBorder = Color(uiColor: .separator).opacity(0.48)
    static let detailBackground = Color(uiColor: .systemBackground)
    static let detailBorder = Color(uiColor: .separator).opacity(0.52)
    static let selectionStripBackground = Color(uiColor: .tertiarySystemBackground)
    static let selectionStripBorder = Color(uiColor: .separator).opacity(0.56)
    #else
    static let panelBackground = Color.gray.opacity(0.10)
    static let panelBorder = Color.gray.opacity(0.22)
    static let segmentBackground = Color.gray.opacity(0.03)
    static let segmentBorder = Color.gray.opacity(0.18)
    static let detailBackground = Color.gray.opacity(0.03)
    static let detailBorder = Color.gray.opacity(0.18)
    static let selectionStripBackground = Color.gray.opacity(0.08)
    static let selectionStripBorder = Color.gray.opacity(0.2)
    #endif
    static let playButtonBackground = Color(red: 0.63, green: 0.90, blue: 0.67)
    static let playButtonSymbol = Color(red: 0.09, green: 0.34, blue: 0.14)
    static let stopButtonBackground = Color(red: 0.95, green: 0.63, blue: 0.63)
    static let stopButtonSymbol = Color(red: 0.45, green: 0.08, blue: 0.08)
}
