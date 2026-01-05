// File: ContentView.swift
// UI
// Root router for Running from Puppies.
// Shows the StartScreenView initially, then transitions to GameHostView when Play is tapped.
//
// Section 1: Imports

import SwiftUI

struct ContentView: View {
    // Section 2: Persistent selection (defaults to Finley)
    @AppStorage("activePlayerId") private var activePlayerId: String = "Finley"

    // Section 3: Router state
    @State private var isPlaying: Bool = false

    // Section 4: GameCore lifetime
    // Keep a single engine instance across the app session so selection/state is consistent.
    private let engine = GameCoreEngine()

    var body: some View {
        Group {
            if isPlaying {
                GameHostView(engine: engine, activePlayerId: activePlayerId)
            } else {
                StartScreenView(
                    activePlayerId: $activePlayerId,
                    isPlaying: $isPlaying
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .runningFromPuppiesQuitRequested)) { _ in
            // Ensure Quit works even if GameHostView cannot dismiss itself (e.g., root router).
            isPlaying = false
        }
    }
}

// End of ContentView.swift
