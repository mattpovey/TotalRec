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

        MenuBarExtra {
            MenuBarRecorderView()
                .environmentObject(appModel)
        } label: {
            Label("TotalRec", systemImage: appModel.menuBarIconName)
        }
        .menuBarExtraStyle(.window)
    }
}
