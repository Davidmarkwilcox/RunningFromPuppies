// GameCoreEngine.swift
// GameCore
// Advances GameState using a fixed timestep.
// Consumes input events as data (no direct UI dependencies).
//
// Section 1: Engine

import Foundation

final class GameCoreEngine {
    private(set) var state = GameState()

    /// Fixed-step simulation advance.
    /// - Parameters:
    ///   - deltaTime: fixed timestep (seconds)
    ///   - inputEvents: edge-triggered input events captured since last tick
    func step(deltaTime: Double, inputEvents: [InputEvent]) {
        // 1) Apply input as discrete impulses (MPS-1 placeholder behavior)
        // Note: This is intentionally minimal and deterministic. Gameplay rules will be expanded later.
        if !inputEvents.isEmpty {
            DebugLog.log("Applied input; playerX(after)=\(state.playerX)")
        }
        
        apply(inputEvents: inputEvents)
        
        if !inputEvents.isEmpty {
            DebugLog.log("Applied input; playerX(after)=\(state.playerX)")
        }

        // 2) Advance time
        state.elapsedTime += deltaTime

        // 3) Placeholder drift to prove fixed-step determinism still works (can be removed later)
        state.playerX += 10.0 * deltaTime
    }

    // MARK: - Private

    private func apply(inputEvents: [InputEvent]) {
        // Discrete movement impulse in points per swipe (placeholder).
        // Keep conservative for now; tune once camera/rooms are implemented.
        let impulse: Double = 60.0

        for event in inputEvents {
            switch event {
            case .swipeLeft:
                state.playerX -= impulse
            case .swipeRight:
                state.playerX += impulse
            case .swipeUp, .swipeDown:
                // Reserved for jump/crouch or lane changes later.
                continue
            }
        }
    }
}

// End of GameCoreEngine.swift
