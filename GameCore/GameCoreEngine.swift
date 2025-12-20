// GameCoreEngine.swift
// GameCore
// Advances GameState using a fixed timestep.
// Consumes input events as data (no direct UI dependencies).
//
// Section 1: Engine

import Foundation

final class GameCoreEngine {
    private(set) var state = GameState()


    // Section 1.1: UI/Runtime-owned snapshot fields
    // These setters allow the UI/runtime to update presentation/runtime parameters
    // without making the entire state mutable from outside the engine.
    func setViewWidth(_ width: Double) {
        state.viewWidth = width
    }

    func setActivePlayerId(_ id: String) {
        state.activePlayerId = id
    }


    // Section 2: Tunables (MPS-2 / MPS-3)
    // NOTE: Keep these as constants for determinism. Adjust only intentionally.
    private let baseRunSpeed: Double = 180.0          // points/sec (player baseline)
    private let impulseDistance: Double = 60.0        // points per swipe
    private let backMargin: Double = 60.0             // points from camera left edge
    private let clampEpsilon: Double = 0.0001         // movement threshold (points)

    // Debug mode is controlled by DebugLog.isEnabled (default Off).
    private let debugLogClampEvents: Bool = true

    /// Fixed-step simulation advance.
    /// - Parameters:
    ///   - deltaTime: fixed timestep (seconds)
    ///   - inputEvents: edge-triggered input events captured since last tick
    func step(deltaTime: Double, inputEvents: [InputEvent]) {
        // Section 3: Deterministic update order
        // 3.1) Capture previous state for derived presentation (idle/run)
        let previousPlayerX = state.playerX

        // 3.2) Advance camera first (world reveal)
        state.cameraX += state.cameraSpeed * deltaTime

        // 3.3) Baseline player motion (auto-run)
        state.playerX += baseRunSpeed * deltaTime

        // 3.4) Apply input impulses
        apply(inputEvents: inputEvents)

        // 3.5) Clamp player into camera-relative window
        let wasClamped = clampPlayerToCameraWindow()

        // 3.6) Advance time last
        state.elapsedTime += deltaTime

        // Section 4: MPS-3 presentation state (deterministic, snapshot-only)
        // 4.1) Facing based on horizontal impulses this tick
        updateFacing(from: inputEvents)

        // 4.2) Idle/run based on movement this tick
        updateAnim(previousPlayerX: previousPlayerX)

        // Section 5: Debug logging (guarded)
        if DebugLog.isEnabled {
            if !inputEvents.isEmpty {
                DebugLog.log(
                    "step(dt=\(deltaTime)) inputs=\(inputEvents) " +
                    "playerX=\(state.playerX) cameraX=\(state.cameraX) viewWidth=\(state.viewWidth)"
                )
            }
            if wasClamped, debugLogClampEvents {
                DebugLog.log("clamp applied: playerX=\(state.playerX) cameraX=\(state.cameraX) viewWidth=\(state.viewWidth)")
            }
        }
    }

    // Section 6: Input application
    private func apply(inputEvents: [InputEvent]) {
        guard !inputEvents.isEmpty else { return }

        for event in inputEvents {
            switch event {
            case .swipeLeft:
                state.playerX -= impulseDistance
            case .swipeRight:
                state.playerX += impulseDistance
            case .swipeUp, .swipeDown:
                // Reserved for jump/crouch or lane changes later.
                continue
            }
        }
    }

    // Section 7: Camera-relative clamp
    @discardableResult
    private func clampPlayerToCameraWindow() -> Bool {
        // Target: player tops out at ~50% of visible width.
        let frontMargin = state.viewWidth * 0.5

        let minPlayerX = state.cameraX + backMargin
        let maxPlayerX = state.cameraX + state.viewWidth - frontMargin

        let original = state.playerX
        state.playerX = min(max(state.playerX, minPlayerX), maxPlayerX)
        return abs(state.playerX - original) > clampEpsilon
    }

    // Section 8: Presentation state helpers (MPS-3)
    private func updateFacing(from inputEvents: [InputEvent]) {
        guard !inputEvents.isEmpty else { return }

        // If both directions appear in the same tick, last one wins (deterministic by event order).
        for event in inputEvents {
            switch event {
            case .swipeLeft:
                state.hasReceivedUserMovementInput = true
                if state.playerFacing != .left, DebugLog.isEnabled {
                    DebugLog.log("playerFacing -> left")
                }
                state.playerFacing = .left

            case .swipeRight:
                state.hasReceivedUserMovementInput = true
                if state.playerFacing != .right, DebugLog.isEnabled {
                    DebugLog.log("playerFacing -> right")
                }
                state.playerFacing = .right

            case .swipeUp, .swipeDown:
                continue
            }
        }
    }

    private func updateAnim(previousPlayerX: Double) {
        // UX: remain idle until the user provides first horizontal movement input
        guard state.hasReceivedUserMovementInput else {
            if state.playerAnim != .idle, DebugLog.isEnabled {
                DebugLog.log("playerAnim -> idle (waiting for first user input)")
            }
            state.playerAnim = .idle
            return
        }

        let delta = abs(state.playerX - previousPlayerX)
        let next: PlayerAnim = (delta > clampEpsilon) ? .run : .idle

        if next != state.playerAnim, DebugLog.isEnabled {
            DebugLog.log("playerAnim -> \(next.rawValue) (deltaX=\(delta))")
        }
        state.playerAnim = next
    }
}

// End of GameCoreEngine.swift
