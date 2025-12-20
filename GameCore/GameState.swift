// GameState.swift
// GameCore
// Authoritative simulation state for Running from Puppies.
// This is the single source of truth for deterministic simulation snapshots consumed by rendering.
//
// Section 1: Data Model

import Foundation

// Section 2: Presentation Enums (snapshot-only)
enum PlayerFacing: String, Codable {
    case left
    case right
}

enum PlayerAnim: String, Codable {
    case idle
    case run
}

// Section 3: GameState
struct GameState {
    // --- Core simulation ---
    // Player horizontal position in world space (points)
    var playerX: Double = 0.0

    // World time since start (seconds)
    var elapsedTime: Double = 0.0

    // --- MPS-2: Camera/world model (authoritative) ---
    // cameraX is the left edge of the visible window in world space.
    var cameraX: Double = 0.0

    // Width of the visible window (points). Runtime/UI should set this from actual view size.
    var viewWidth: Double = 390.0

    // Constant forward camera speed (points/sec).
    var cameraSpeed: Double = 120.0

    // --- MPS-3: Player presentation selection + state (snapshot-only) ---
    // Active player "skin" identifier used by rendering to pick textures (e.g., "Finley").
    // UI/runtime owns this value; GameCore does not change it.
    var activePlayerId: String = "Finley"

    // Player starts idle until the user provides first movement input (MPS-3 UX tweak)
    var hasReceivedUserMovementInput: Bool = true
    
    // Facing direction for rendering (set deterministically by GameCore from inputs).
    var playerFacing: PlayerFacing = .right

    // Minimal animation state for rendering (set deterministically by GameCore from movement).
    var playerAnim: PlayerAnim = .idle
}

// End of GameState.swift
