import Foundation
import SwiftUI

enum TransientNoticeStyle: Equatable {
    case info
    case success
    case warning
    case error
}

struct TransientNotice: Identifiable, Equatable {
    let id: UUID
    let message: String
    let style: TransientNoticeStyle

    init(id: UUID = UUID(), message: String, style: TransientNoticeStyle) {
        self.id = id
        self.message = message
        self.style = style
    }
}

struct TransientNoticeBanner: View {
    let notice: TransientNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(TotalRecGlass.accentForeground(tint))
                .padding(.top, 2)

            Text(notice.message)
                .font(.footnote)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Button("Dismiss", action: onDismiss)
                .totalRecGlassButton()
                .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .totalRecStaticRoundedRect(cornerRadius: 12, tint: tint)
    }

    private var systemImage: String {
        switch notice.style {
        case .info:
            return "info.circle.fill"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch notice.style {
        case .info:
            return TotalRecGlass.captureBlue
        case .success:
            return TotalRecGlass.successGreen
        case .warning:
            return TotalRecGlass.warningAmber
        case .error:
            return TotalRecGlass.recordingRed
        }
    }
}
