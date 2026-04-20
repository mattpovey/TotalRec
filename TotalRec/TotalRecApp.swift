//
//  TotalRecApp.swift
//  TotalRec
//
//  Created by Matthew Povey on 10/11/2025.
//

import SwiftUI

@main
struct TotalRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appModel = AppModel.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appModel)
        }
        .defaultSize(width: 1100, height: 720)

#if os(macOS)
        Settings {
            TotalRecSettingsView()
                .environmentObject(appModel)
        }
#endif

        MenuBarExtra {
            MenuBarRecorderView()
                .environmentObject(appModel)
        } label: {
            MenuBarStatusLabel(stage: appModel.activeSession?.stage)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarStatusLabel: View {
    let stage: SessionStage?

    var body: some View {
        Label {
            Text("TotalRec")
        } icon: {
            Image(systemName: stage?.totalRecMenuBarIconName ?? SessionStage.idle.totalRecMenuBarIconName)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(stage?.totalRecStatusTint ?? SessionStage.idle.totalRecStatusTint)
        }
        .accessibilityLabel(stage?.totalRecMenuBarTitle ?? "TotalRec")
    }
}
