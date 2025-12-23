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
    @StateObject private var viewModel = AppViewModel()
    @Environment(\.scenePhase) var scenePhase
    
    init() {
        if let icon = NSImage(named: "PawnPilotGlyph") ??
            (Bundle.main.url(forResource: "PawnPilotGlyph", withExtension: "png").flatMap { NSImage(contentsOf: $0) }) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Image…", action: viewModel.openImageFromPanel)
                    .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Move", action: viewModel.undo)
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!viewModel.canUndo)
                Button("Redo Move", action: viewModel.redo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!viewModel.canRedo)
            }
            CommandGroup(after: .undoRedo) {
                Divider()
                Button("Reset Board", action: viewModel.resetBoard)
                Button("Rotate Position", action: viewModel.rotatePosition)
                Button("Flip Board") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        viewModel.orientationWhiteAtBottom.toggle()
                    }
                }
            }
            CommandGroup(replacing: .pasteboard) { }
            CommandGroup(replacing: .textEditing) { }
            CommandGroup(replacing: .textFormatting) { }
        }
    }
}
