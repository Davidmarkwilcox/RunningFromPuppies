// GameCoreEngine_20251231-2348.swift
// Runs deterministic game simulation ticks (GameCore). Consumes InputEvents, advances timers/score, and updates GameState. Rendering reads state but does not mutate it.
//
// Sections:
// 1. Imports
// 2. Types
// 3. Logic
//
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
    // Jump tunables (world-space points, deterministic)
    private let jumpVelocity: Double = 900.0          // points/sec (initial upward velocity)
    private let gravity: Double = -2400.0             // points/sec^2 (downward acceleration)
    private let maxFallSpeed: Double = -3000.0         // points/sec (terminal velocity clamp)
    private let backMargin: Double = 60.0             // points from camera left edge
    private let clampEpsilon: Double = 0.0001         // movement threshold (points)

    // Debug mode is controlled by DebugLog.isEnabled (default Off).
    private let debugLogClampEvents: Bool = true

    /// Fixed-step simulation advance.
    /// - Parameters:
    ///   - deltaTime: fixed timestep (seconds)
    ///   - inputEvents: edge-triggered input events captured since last tick
    func step(deltaTime: Double, inputEvents: [InputEvent]) {        // Section 2.10: Pause gate. Process togglePause even while paused.
        let didTogglePause = inputEvents.contains(.togglePause)
        if didTogglePause {
            state.isPaused.toggle()
        }
        if state.isPaused {
            // While paused, do not advance simulation or accumulate additional state.
            return
        }

        // Section 2.9: World & level timers (authoritative)
        state.elapsedTime += deltaTime
        state.elapsedLevelTime += deltaTime

        // Section 2.9.1: Scoring (authoritative)
        // v1 rule: +10 points per second survived. No accumulation while paused (handled by pause gate above).
        // We accumulate fractional points deterministically using scoreRemainder.
        state.scoreRemainder += deltaTime * 10.0
        let wholePoints = Int(state.scoreRemainder)
        if wholePoints > 0 {
            state.score += wholePoints
            state.scoreRemainder -= Double(wholePoints)
        }


        let filteredInputEvents = inputEvents.filter { $0 != .togglePause }
        // Section 3: Deterministic update order
        // 3.1) Capture previous state for derived presentation (idle/run)
        let previousPlayerX = state.playerX

        // 3.2) Apply input first so direction changes and hard stops take effect immediately.
        apply(inputEvents: filteredInputEvents)

        // 3.3) Advance camera (world reveal). If tap-stop is active, cameraSpeed will be 0.
        state.cameraX += state.cameraSpeed * deltaTime

        // 3.4) Baseline player motion (auto-run follows facing direction)
        if !state.isIdleForcedByTap {
            let dir: Double = (state.playerFacing == .right) ? 1.0 : -1.0
            state.playerX += dir * baseRunSpeed * deltaTime
        }

        // 3.5) Vertical physics (jump + gravity)
        integrateVertical(deltaTime: deltaTime)

        // 3.6) Clamp player into camera-relative window
        let wasClamped = clampPlayerToCameraWindow()

        // 3.7) Derive room strip position (authoritative)
        updateCurrentRoom()

        // 3.8) Derive facing from movement delta (unless clamped), for deterministic rendering
        // Note: swipe left/right explicitly sets facing in apply(); this keeps facing correct for non-swipe forces.
        let dx = state.playerX - previousPlayerX
        if abs(dx) > 0.0001 && !wasClamped {
            updateFacing(from: dx)
        }

        // 3.9) Derive minimal anim state from movement + tap-stop
        updateAnim(previousPlayerX: previousPlayerX)
    }

func apply(inputEvents: [InputEvent]) {
        guard !inputEvents.isEmpty else { return }

        for event in inputEvents {
            switch event {

            case .togglePause:
                // Handled in step() pause gate; ignore here.
                continue

            case .swipeLeft:
                // Gameplay contract (v1): swipe left turns the player and continues auto-run left.
                // Also resumes motion if it was previously stopped by tap.
                if state.isIdleForcedByTap {
                    state.isIdleForcedByTap = false
                    state.cameraSpeed = defaultCameraSpeed
                }
                state.playerFacing = .left
                state.playerX -= impulseDistance

            case .swipeRight:
                // Gameplay contract (v1): swipe right turns the player and continues auto-run right.
                // Also resumes motion if it was previously stopped by tap.
                if state.isIdleForcedByTap {
                    state.isIdleForcedByTap = false
                    state.cameraSpeed = defaultCameraSpeed
                }
                state.playerFacing = .right
                state.playerX += impulseDistance

            case .swipeUp:
                // Jump (v1): no mid-air control; no double jump.
                if isGrounded() {
                    state.playerVY = jumpVelocity
                    GameState.debug("Jump triggered vy=\(jumpVelocity)")
                } else {
                    GameState.debug("Jump ignored (not grounded) y=\(state.playerY) vy=\(state.playerVY)")
                }

            case .swipeDown:
                // Reserved for slide/crouch (future). Ignored for now per v1 scope.
                break

            case .tapPlayer:
                // Gameplay rule: tap on player = immediate hard stop (horizontal), camera stops too.
                state.isIdleForcedByTap = true
                GameState.debug("Tap stop triggered: cameraSpeed=0")

            }
        }
    }

    // Section 3.5: Vertical physics integration (jump + gravity)
    private func integrateVertical(deltaTime: Double) {
        // Apply gravity only when airborne or moving vertically.
        guard !isGrounded() || abs(state.playerVY) > clampEpsilon else { return }

        state.playerVY += gravity * deltaTime
        if state.playerVY < maxFallSpeed { state.playerVY = maxFallSpeed }

        state.playerY += state.playerVY * deltaTime

        // Ground collision (simple ground plane at y=0)
        if state.playerY <= 0.0 {
            state.playerY = 0.0
            state.playerVY = 0.0
        }
    }

    // Section 3.5.1: Grounded check
    private func isGrounded() -> Bool {
        return state.playerY <= clampEpsilon && abs(state.playerVY) <= clampEpsilon
    }

private func clampPlayerToCameraWindow() -> Bool {
        // Target: player tops out at ~50% of visible width.
        let frontMargin: Double = 60.0  // allow player to approach the right edge
        let minPlayerX = state.cameraX + backMargin
        let maxPlayerX = state.cameraX + state.viewWidth - frontMargin

        let original = state.playerX
        state.playerX = min(max(state.playerX, minPlayerX), maxPlayerX)
        return abs(state.playerX - original) > clampEpsilon
    }

    // Section 6: Room Derivation (authoritative, deterministic)
    private func updateCurrentRoom() {
        // For MPS, treat every room as 1 unit wide. (Entryway 2x, etc. can be added later.)
        // This keeps currentRoomIndex/currentRoomOriginX coherent for rendering and debug.
        let roomWidth = state.oneUnitRoomWidth
        guard roomWidth > 0, !state.roomIds.isEmpty else { return }

        // Determine which room tile we are in based on playerX. Use floor for stable boundaries.
        let logicalRoomIndex = Int(floor(state.playerX / roomWidth))

        // Wrap into the canonical room type list.
        let count = state.roomIds.count
        let wrapped = ((logicalRoomIndex % count) + count) % count
        state.currentRoomIndex = wrapped

        // Origin is the world-space X at the left edge of the current logical room.
        state.currentRoomOriginX = Double(logicalRoomIndex) * roomWidth
    }

    // Section 8: Presentation state helpers (MPS-3)
    private func updateFacing(from deltaX: Double) {
        // Only adjust if there was meaningful movement and the player is not being hard-clamped by the camera window.
        guard abs(deltaX) > clampEpsilon else { return }

        if deltaX > 0 {
            if state.playerFacing != .right, DebugLog.isEnabled {
                DebugLog.log("playerFacing -> right (movement)")
            }
            state.playerFacing = .right
        } else if deltaX < 0 {
            if state.playerFacing != .left, DebugLog.isEnabled {
                DebugLog.log("playerFacing -> left (movement)")
            }
            state.playerFacing = .left
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
// End of GameCoreEngine_20251231-2348.swift
