import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let appModel = AppModel.shared

        guard appModel.hasProtectedActivity else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if appModel.isRecording {
            alert.messageText = "A recording is still in progress."
            alert.informativeText = "Keep TotalRec running so the recording can be stopped safely and saved. You can stop the recording first, or quit immediately and risk losing the in-progress capture."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Stop Safely and Quit")
            alert.addButton(withTitle: "Quit Anyway")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return .terminateCancel
            case .alertSecondButtonReturn:
                Task { @MainActor in
                    let didStop = await appModel.stopRecording()
                    sender.reply(toApplicationShouldTerminate: didStop)
                    if !didStop {
                        sender.activate(ignoringOtherApps: true)
                    }
                }
                return .terminateLater
            default:
                return .terminateNow
            }
        } else {
            alert.messageText = "Audio processing is still in progress."
            alert.informativeText = "Keep TotalRec running until the current work finishes. Quitting now can interrupt the session."
            alert.addButton(withTitle: "Keep Running")
            alert.addButton(withTitle: "Quit Anyway")

            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
    }
}
