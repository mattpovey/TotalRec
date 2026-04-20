import SwiftUI
#if os(macOS)
import AppKit
#endif

enum TotalRecGlass {
    enum TintUsage {
        case ambient
        case panel
        case secondarySurface
        case pill
        case button
    }

    static let panelCornerRadius: CGFloat = 18
    static let nestedPanelCornerRadius: CGFloat = 16
    static let insetCornerRadius: CGFloat = 14
    static let chipCornerRadius: CGFloat = 14
    static let badgePadding = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)

    static let captureBlue = Color(red: 0.25, green: 0.54, blue: 0.85)
    static let recordingRed = Color(red: 0.79, green: 0.33, blue: 0.39)
    static let transcriptViolet = Color(red: 0.40, green: 0.34, blue: 0.82)
    static let insightsGreen = Color(red: 0.20, green: 0.58, blue: 0.40)
    static let warningAmber = Color(red: 0.72, green: 0.51, blue: 0.24)
    static let successGreen = Color(red: 0.23, green: 0.56, blue: 0.39)
    static let neutralTint = Color(red: 0.45, green: 0.47, blue: 0.53)

    static func glass(
        tint: Color? = nil,
        usage: TintUsage = .panel,
        interactive: Bool = false
    ) -> Glass {
        var glass = Glass.regular
        if let tint {
            glass = glass.tint(tonedTint(tint, usage: usage))
        }
        if interactive {
            glass = glass.interactive()
        }
        return glass
    }

    static func tonedTint(_ tint: Color, usage: TintUsage) -> Color {
        #if os(macOS)
        let base = NSColor(tint).usingColorSpace(.deviceRGB)
            ?? NSColor.controlAccentColor.usingColorSpace(.deviceRGB)
            ?? .systemBlue
        let neutral = neutralBackground(for: usage)
        let blendFraction: CGFloat
        let alpha: CGFloat

        switch usage {
        case .ambient:
            blendFraction = 0.93
            alpha = 0.52
        case .panel:
            blendFraction = 0.88
            alpha = 0.84
        case .secondarySurface:
            blendFraction = 0.84
            alpha = 0.88
        case .pill:
            blendFraction = 0.80
            alpha = 0.92
        case .button:
            blendFraction = 0.76
            alpha = 0.94
        }

        let blended = base.blended(withFraction: blendFraction, of: neutral) ?? base
        return Color(nsColor: blended.withAlphaComponent(alpha))
        #else
        switch usage {
        case .ambient:
            return tint.opacity(0.12)
        case .panel:
            return tint.opacity(0.18)
        case .secondarySurface:
            return tint.opacity(0.22)
        case .pill:
            return tint.opacity(0.28)
        case .button:
            return tint.opacity(0.34)
        }
        #endif
    }

    static func accentForeground(_ tint: Color) -> Color {
        #if os(macOS)
        let base = NSColor(tint).usingColorSpace(.deviceRGB)
            ?? NSColor.controlAccentColor.usingColorSpace(.deviceRGB)
            ?? .systemBlue
        let label = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
        let blended = base.blended(withFraction: 0.58, of: label) ?? base
        return Color(nsColor: blended)
        #else
        return tint
        #endif
    }

    static var staticPanelFill: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor).opacity(0.94)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    static var staticInsetFill: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor).opacity(0.97)
        #else
        Color(.systemBackground)
        #endif
    }

    static var staticSurfaceBorderBase: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor).opacity(0.22)
        #else
        Color(.separator).opacity(0.18)
        #endif
    }

    static var staticShadowColor: Color {
        Color.black.opacity(0.05)
    }

    static func staticSurfaceBorder(tint: Color?, usage: TintUsage) -> Color {
        guard let tint else { return staticSurfaceBorderBase }
        return tonedTint(tint, usage: usage).opacity(0.32)
    }

    #if os(macOS)
    private static func neutralBackground(for usage: TintUsage) -> NSColor {
        switch usage {
        case .ambient:
            return NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
        case .panel:
            return NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
        case .secondarySurface:
            return NSColor.controlBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
        case .pill:
            return NSColor.controlBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
        case .button:
            return NSColor.controlBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
        }
    }
    #endif
}

struct TotalRecGlassCluster<Content: View>: View {
    let spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    }
}

struct TotalRecAmbientBackground: View {
    let accent: Color
    let secondaryAccent: Color

    var body: some View {
        ZStack {
            LinearGradient(
                colors: baseGradientColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(TotalRecGlass.tonedTint(accent, usage: .ambient).opacity(0.55))
                .frame(width: 560, height: 560)
                .blur(radius: 130)
                .offset(x: -260, y: -210)

            Circle()
                .fill(TotalRecGlass.tonedTint(secondaryAccent, usage: .ambient).opacity(0.48))
                .frame(width: 460, height: 460)
                .blur(radius: 140)
                .offset(x: 270, y: 220)

            RoundedRectangle(cornerRadius: 180, style: .continuous)
                .fill(.white.opacity(0.06))
                .frame(width: 460, height: 280)
                .blur(radius: 150)
                .offset(x: 210, y: -230)
        }
        .ignoresSafeArea()
    }

    private var baseGradientColors: [Color] {
        #if os(macOS)
        [
            Color(nsColor: .windowBackgroundColor),
            Color(nsColor: .controlBackgroundColor).opacity(0.98),
            Color(nsColor: .underPageBackgroundColor)
        ]
        #else
        [
            Color(.systemBackground),
            Color(.secondarySystemBackground),
            Color(.tertiarySystemBackground)
        ]
        #endif
    }
}

enum TotalRecActivityMotion {
    case none
    case pulse
    case spin

    var interval: TimeInterval {
        switch self {
        case .none:
            return 60
        case .pulse:
            return 0.78
        case .spin:
            return 0.16
        }
    }

    var animation: Animation {
        switch self {
        case .none:
            return .default
        case .pulse:
            return .easeInOut(duration: interval)
        case .spin:
            return .linear(duration: interval)
        }
    }
}

extension SessionStage {
    var totalRecMenuBarIconName: String {
        switch self {
        case .recording:
            return "record.circle.fill"
        case .preparingRecording:
            return "record.circle.dotted"
        case .mixingDown, .transcribing, .generatingInsights, .importingAudio:
            return "gearshape.2"
        case .failed:
            return "exclamationmark.triangle"
        case .readyToTranscribe, .completed:
            return "waveform.and.mic"
        case .idle:
            return "waveform"
        }
    }

    var totalRecMenuBarTitle: String {
        switch self {
        case .recording:
            return "Recording"
        case .preparingRecording:
            return "Preparing Recording"
        case .mixingDown:
            return "Mixing Down"
        case .transcribing:
            return "Transcribing"
        case .generatingInsights:
            return "Generating Notes"
        case .importingAudio:
            return "Importing Audio"
        case .readyToTranscribe:
            return "Ready to Transcribe"
        case .completed:
            return "Session Saved"
        case .failed:
            return "Attention Needed"
        case .idle:
            return "Ready"
        }
    }

    var totalRecStatusLabel: String {
        switch self {
        case .idle:
            return "Idle"
        case .preparingRecording:
            return "Preparing"
        case .recording:
            return "Recording"
        case .mixingDown:
            return "Mixing"
        case .importingAudio:
            return "Importing"
        case .readyToTranscribe:
            return "Ready"
        case .transcribing:
            return "Transcribing"
        case .generatingInsights:
            return "Notes"
        case .completed:
            return "Complete"
        case .failed:
            return "Attention"
        }
    }

    var totalRecStatusIcon: String {
        switch self {
        case .idle:
            return "circle"
        case .preparingRecording:
            return "record.circle.dotted"
        case .recording:
            return "record.circle.fill"
        case .mixingDown:
            return "slider.horizontal.3"
        case .importingAudio:
            return "square.and.arrow.down"
        case .readyToTranscribe:
            return "waveform"
        case .transcribing:
            return "text.badge.clock"
        case .generatingInsights:
            return "sparkles.rectangle.stack"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var totalRecStatusTint: Color {
        switch self {
        case .recording:
            return TotalRecGlass.recordingRed
        case .preparingRecording, .mixingDown, .importingAudio:
            return TotalRecGlass.captureBlue
        case .transcribing:
            return TotalRecGlass.transcriptViolet
        case .generatingInsights:
            return TotalRecGlass.insightsGreen
        case .readyToTranscribe, .completed:
            return TotalRecGlass.successGreen
        case .failed:
            return TotalRecGlass.warningAmber
        case .idle:
            return TotalRecGlass.neutralTint
        }
    }

    var totalRecActivityMotion: TotalRecActivityMotion {
        switch self {
        case .recording, .preparingRecording:
            return .pulse
        case .mixingDown, .importingAudio, .transcribing, .generatingInsights:
            return .spin
        case .idle, .readyToTranscribe, .completed, .failed:
            return .none
        }
    }

    var totalRecShowsLiveActivity: Bool {
        totalRecActivityMotion != .none
    }

    var totalRecProgressHeadline: String {
        switch self {
        case .preparingRecording:
            return "Preparing recording"
        case .recording:
            return "Recording in progress"
        case .mixingDown:
            return "Mixing audio"
        case .importingAudio:
            return "Importing audio"
        case .transcribing:
            return "Transcription in progress"
        case .generatingInsights:
            return "Generating insights"
        case .readyToTranscribe:
            return "Ready to transcribe"
        case .completed:
            return "Session complete"
        case .failed:
            return "Needs attention"
        case .idle:
            return "Idle"
        }
    }

    var totalRecProgressSupportText: String {
        switch self {
        case .preparingRecording:
            return "Capture permissions and recording inputs are being prepared now."
        case .recording:
            return "Audio capture is live. Stop recording when you are ready to save and transcribe."
        case .mixingDown:
            return "The recorded tracks are being merged into a single audio file for review and transcription."
        case .importingAudio:
            return "The source audio is being copied into this session and prepared for transcription."
        case .transcribing:
            return "Partial text can appear while the transcript is assembled. Session switching stays locked until the run completes."
        case .generatingInsights:
            return "An insight artifact is being generated from the current transcript. You can keep reviewing the session while this finishes."
        case .readyToTranscribe:
            return "Audio is ready for the next transcription run."
        case .completed:
            return "The session artifacts are saved and ready for review."
        case .failed:
            return "Review the latest error and retry when the issue is resolved."
        case .idle:
            return "No long-running activity is in progress."
        }
    }
}

struct TotalRecActivitySymbol: View {
    let systemImage: String
    let tint: Color
    let motion: TotalRecActivityMotion
    var size: CGFloat = 16
    var weight: Font.Weight = .semibold

    var body: some View {
        if motion == .none {
            icon(step: 0)
        } else {
            TimelineView(.periodic(from: .now, by: motion.interval)) { context in
                let step = Int(context.date.timeIntervalSinceReferenceDate / motion.interval)
                icon(step: step)
                    .animation(motion.animation, value: step)
            }
        }
    }

    private func icon(step: Int) -> some View {
        let isExpanded = !step.isMultiple(of: 2)
        let rotation = Double(step % 8) * 45

        return Image(systemName: systemImage)
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(TotalRecGlass.accentForeground(tint))
            .scaleEffect(motion == .pulse ? (isExpanded ? 1.08 : 0.94) : 1)
            .opacity(motion == .pulse ? (isExpanded ? 1 : 0.76) : 1)
            .rotationEffect(motion == .spin ? .degrees(rotation) : .zero)
    }
}

extension View {
    func totalRecGlassPanel(
        cornerRadius: CGFloat = TotalRecGlass.panelCornerRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        glassEffect(
            TotalRecGlass.glass(tint: tint, usage: .panel, interactive: interactive),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    func totalRecGlassPill(
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        glassEffect(
            TotalRecGlass.glass(tint: tint, usage: .pill, interactive: interactive),
            in: Capsule()
        )
    }

    func totalRecGlassRoundedRect(
        cornerRadius: CGFloat = TotalRecGlass.insetCornerRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        glassEffect(
            TotalRecGlass.glass(tint: tint, usage: .secondarySurface, interactive: interactive),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    @ViewBuilder
    func totalRecGlassButton(prominent: Bool = false, tint: Color? = nil) -> some View {
        if prominent {
            buttonStyle(.glassProminent)
        } else if let tint {
            buttonStyle(.glass(TotalRecGlass.glass(tint: tint, usage: .button)))
        } else {
            buttonStyle(.glass)
        }
    }

    func totalRecReadableInset(cornerRadius: CGFloat = TotalRecGlass.insetCornerRadius) -> some View {
        background(readableInsetFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(readableInsetBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    func totalRecStaticPanel(
        cornerRadius: CGFloat = TotalRecGlass.panelCornerRadius,
        tint: Color? = nil
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(TotalRecGlass.staticPanelFill, in: shape)
            .overlay {
                if let tint {
                    shape.fill(TotalRecGlass.tonedTint(tint, usage: .panel).opacity(0.14))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape.stroke(
                    TotalRecGlass.staticSurfaceBorder(tint: tint, usage: .panel),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: TotalRecGlass.staticShadowColor, radius: 10, y: 4)
    }

    func totalRecStaticRoundedRect(
        cornerRadius: CGFloat = TotalRecGlass.insetCornerRadius,
        tint: Color? = nil
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(TotalRecGlass.staticInsetFill, in: shape)
            .overlay {
                if let tint {
                    shape.fill(TotalRecGlass.tonedTint(tint, usage: .secondarySurface).opacity(0.12))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape.stroke(
                    TotalRecGlass.staticSurfaceBorder(tint: tint, usage: .secondarySurface),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: TotalRecGlass.staticShadowColor.opacity(0.8), radius: 4, y: 2)
    }

    func totalRecStaticPill(tint: Color? = nil) -> some View {
        let shape = Capsule()
        return background(TotalRecGlass.staticInsetFill, in: shape)
            .overlay {
                if let tint {
                    shape.fill(TotalRecGlass.tonedTint(tint, usage: .pill).opacity(0.14))
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                shape.stroke(
                    TotalRecGlass.staticSurfaceBorder(tint: tint, usage: .pill),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
    }

    private var readableInsetFill: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor).opacity(0.82)
        #else
        Color(.secondarySystemBackground)
        #endif
    }

    private var readableInsetBorder: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor).opacity(0.42)
        #else
        Color(.separator).opacity(0.4)
        #endif
    }
}
