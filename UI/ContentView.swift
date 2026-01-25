// File: ContentView.swift
// UI
// Root router for Running from Puppies.
// Shows the StartScreenView initially (wrapped in a NavigationStack for toolbars/navigation),
// then transitions to GameHostView when Play is tapped.
//
// Interactions:
// - StartScreenView drives isPlaying via binding.
// - GameHostView posts .runningFromPuppiesQuitRequested to return to the start screen.
//
// Section 1: Imports

import SwiftUI

struct ContentView: View {
    // Section 2: Persistent selection (defaults to Finley)
    @AppStorage("activePlayerId") private var activePlayerId: String = "Finley"
    @AppStorage("startingLevel") private var startingLevel: Int = 1

    // Section 3: Router state
    @State private var isPlaying: Bool = false

    // Section 4: GameCore lifetime
    // Keep a single engine instance across the app session so selection/state is consistent.
    private let engine = GameCoreEngine()

    var body: some View {
        Group {
            if isPlaying {
                GameHostView(engine: engine, activePlayerId: activePlayerId, startingLevel: startingLevel)
            } else {
                // Section 5: Navigation shell for non-game screens (Leaderboards / Settings)
                NavigationStack {
                    StartScreenView(
                        activePlayerId: $activePlayerId,
                        isPlaying: $isPlaying,
                        startingLevel: $startingLevel
                    )
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .runningFromPuppiesQuitRequested)) { _ in
            // Ensure Quit works even if GameHostView cannot dismiss itself (e.g., root router).
            isPlaying = false
        }
    }
}

// End of ContentView.swift
