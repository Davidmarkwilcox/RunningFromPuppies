// GameState.swift
// GameCore
// Authoritative simulation state for Running from Puppies.
// Defines the minimal state required for MPS-1.
// Interacts with GameCoreEngine only.
//
// Section 1: Data Model

import Foundation

struct GameState {
    // Player horizontal position in world space (points)
    var playerX: Double = 0.0

    // World time since start (seconds)
    var elapsedTime: Double = 0.0
}

// End of GameState.swift
