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

    func setViewHeight(_ height: Double) {
        state.viewHeight = height
    }

    func setActivePlayerId(_ id: String) {
        state.activePlayerId = id
    }


    // Section 2: Tunables (MPS-2 / MPS-3)
    // NOTE: Keep these as constants for determinism. Adjust only intentionally.
    private let baseRunSpeed: Double = 180.0          // points/sec (player baseline)
    private let defaultCameraSpeed: Double = 120.0   // points/sec (camera baseline)
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
        if !state.isIdleForcedByTap {
            state.playerX += baseRunSpeed * deltaTime
        }

        // 3.4) Apply input impulses
        apply(inputEvents: inputEvents)

        // 3.5) Clamp player into camera-relative window
        let wasClamped = clampPlayerToCameraWindow()
        // 3.5.1) Derive room strip position (authoritative, deterministic)
        updateRoomProgress()

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
                    "playerX=\(state.playerX) cameraX=\(state.cameraX) viewWidth=\(state.viewWidth) viewHeight=\(state.viewHeight)"
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
                // Resume motion if it was previously stopped by tap.
                if state.isIdleForcedByTap {
                    state.isIdleForcedByTap = false
                    state.cameraSpeed = defaultCameraSpeed
                }
                state.playerX -= impulseDistance
            case .swipeRight:
                // Resume motion if it was previously stopped by tap.
                if state.isIdleForcedByTap {
                    state.isIdleForcedByTap = false
                    state.cameraSpeed = defaultCameraSpeed
                }
                state.playerX += impulseDistance
            case .tapPlayer:
                // Gameplay rule: tap on player = immediate hard stop.
                state.isIdleForcedByTap = true
                state.cameraSpeed = 0.0
                // Note: baseline run is skipped in step() when isIdleForcedByTap is true.
            case .swipeUp, .swipeDown:
                // Reserved for jump/crouch or lane changes later.
                continue
            }
        }
    }

    // Section 6.5: Room strip derivation (MPS-5)
    // Section 6.5: Room strip derivation (MPS-5)
    private func updateRoomProgress() {
        let ids = state.roomIds
        let widths = state.roomWidths

        guard !ids.isEmpty, ids.count == widths.count else {
            state.currentRoomIndex = 0
            state.currentRoomOriginX = 0.0
            return
        }

        // Total “cycle” width for one full house pass.
        let cycleWidth = widths.reduce(0.0, +)
        guard cycleWidth > 0 else {
            state.currentRoomIndex = 0
            state.currentRoomOriginX = 0.0
            return
        }

        // Position within the repeating cycle (wrap-safe).
        // Note: playerX is expected to be >= 0 in the current design, but we handle negatives deterministically anyway.
        var xInCycle = state.playerX.truncatingRemainder(dividingBy: cycleWidth)
        if xInCycle < 0 { xInCycle += cycleWidth }

        // Find which room contains xInCycle.
        var cumulative = 0.0
        var index = 0
        for (i, w) in widths.enumerated() {
            let next = cumulative + w
            if xInCycle < next {
                index = i
                break
            }
            cumulative = next
        }

        state.currentRoomIndex = index

        // World-space origin X for the current room tile:
        // (start of the cycle containing playerX) + (start offset of this room within the cycle)
        let cycleStartX = state.playerX - xInCycle
        state.currentRoomOriginX = cycleStartX + cumulative
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
            case .tapPlayer:
                // Tap does not affect facing.
                continue
            }
        }
    }

    private func updateAnim(previousPlayerX: Double) {
        // Tap-to-idle: forced hard stop overrides run/idle derivation until resumed by horizontal swipe.
        if state.isIdleForcedByTap {
            if state.playerAnim != .idle, DebugLog.isEnabled {
                DebugLog.log("playerAnim -> idle (forced by tap)")
            }
            state.playerAnim = .idle
            return
        }
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
