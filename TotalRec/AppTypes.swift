import Foundation

enum WorkflowSection: String, CaseIterable, Identifiable {
    case capture = "Capture"
    case transcript = "Transcript"
    case insights = "Insights"

    var id: String { rawValue }
}
