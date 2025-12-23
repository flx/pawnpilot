//
//  PawnPilotApp.swift
//  PawnPilot
//
//  Created by Felix Matschke on 12/23/25.
//

import SwiftUI
import AppKit

@main
struct PawnPilotApp: App {
    @Environment(\.scenePhase) var scenePhase
    
    init() {
        if let icon = NSImage(named: "PawnPilotGlyph") ??
            (Bundle.main.url(forResource: "PawnPilotGlyph", withExtension: "png").flatMap { NSImage(contentsOf: $0) }) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
