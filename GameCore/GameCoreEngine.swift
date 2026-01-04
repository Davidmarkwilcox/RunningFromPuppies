// File: GameCoreEngine.swift
// GameCoreEngine_20260103-1500.swift
// Purpose: Runs deterministic game simulation ticks (GameCore). Consumes InputEvents, advances timers/score,
//          updates GameState for player/camera/rooms, and (v1) updates a single active puppy (enemy) with
//          deterministic pseudo-random behavior.
//
// This file must remain SpriteKit-agnostic.
//
// Sections:
// 1. Imports
// 2. Engine + Runtime setters
// 3. Tunables
// 4. Fixed-step tick (step)
// 5. Input application
// 6. Player physics/helpers
// 7. Room derivation
// 8. Puppy system (spawn, RNG, update, capture)
//
// End-of-file marker is included at the bottom.

// Section 1: Imports
import Foundation

// Section 2: Engine
final class GameCoreEngine {
    // Section 2.1: Authoritative state (read by rendering, mutated only here)
    private(set) var state = GameState()

    // Section 2.2: Debug state
    private var lastRoomIndexLogged: Int = -1

    // -------------------------------------------------------------------------
    // Section 2.3: UI/Runtime-owned snapshot fields
    // -------------------------------------------------------------------------
    func setViewWidth(_ width: Double) {
        state.viewWidth = width
    }

    func setViewHeight(_ height: Double) {
        state.viewHeight = height
    }

    func setActivePlayerId(_ id: String) {
        state.activePlayerId = id
    }

    func setActivePuppyId(_ id: String) {
        state.activePuppyId = id
        // Reset puppy initialization so the next tick will spawn deterministically for the new puppy.
        state.puppyHasSpawnedThisLevel = false
        state.puppyDecisionTimeRemaining = 0.0
        state.puppyDecisionMode = 0
    }

    // -------------------------------------------------------------------------
    // Section 3: Tunables (deterministic constants)
    // -------------------------------------------------------------------------
    // Player
    private let baseRunSpeed: Double = 180.0          // points/sec (player baseline)
    private let defaultCameraSpeed: Double = 120.0    // points/sec (camera baseline)
    private let impulseDistance: Double = 60.0        // points per swipe

    // Jump
    private let jumpVelocity: Double = 900.0          // points/sec
    private let gravity: Double = -2400.0             // points/sec^2
    private let maxFallSpeed: Double = -3000.0        // points/sec
    private let clampEpsilon: Double = 0.0001

    // Camera window clamp
    private let backMargin: Double = 60.0

    // Debug mode is controlled by DebugLog.isEnabled (default Off).
    private let debugLogClampEvents: Bool = true

    // -------------------------------------------------------------------------
    // Section 4: Fixed-step simulation advance
    // -------------------------------------------------------------------------
    func step(deltaTime: Double, inputEvents: [InputEvent]) {
        // Section 4.0: Reset per-tick flags
        state.didJustCaptureThisTick = false

        // Section 4.1: Pause gate. Process togglePause even while paused.
        let didTogglePause = inputEvents.contains(.togglePause)
        if didTogglePause {
            state.isPaused.toggle()
        }
        if state.isPaused {
            return
        }

        // Section 4.2: If captured, run only the deterministic post-capture timer.
        // Level is considered ended; runtime can transition once postCaptureTime >= postCaptureDuration.
        if state.runPhase == .captured {
            state.elapsedTime += deltaTime
            state.postCaptureTime += deltaTime

            // Keep presentation stable
            state.playerAnim = .captured
            state.puppyAnim = .lick

            if DebugLog.isEnabled {
                DebugLog.log("RunPhase=captured postCaptureTime=\(String(format: "%.2f", state.postCaptureTime))/\(String(format: "%.2f", state.postCaptureDuration))")
            }
            return
        }

        // Section 4.3: World & level timers (authoritative)
        state.elapsedTime += deltaTime
        state.elapsedLevelTime += deltaTime

        // Section 4.4: Scoring (authoritative)
        // v1 rule: +10 points per second survived.
        state.scoreRemainder += deltaTime * 10.0
        let wholePoints = Int(state.scoreRemainder)
        if wholePoints > 0 {
            state.score += wholePoints
            state.scoreRemainder -= Double(wholePoints)
        }

        // Section 4.5: Filter togglePause (already handled)
        let filteredInputEvents = inputEvents.filter { $0 != .togglePause }

        // Section 4.6: Deterministic update order
        let previousPlayerX = state.playerX

        // 4.6.1) Apply input first
        apply(inputEvents: filteredInputEvents)

        // 4.6.2) Camera reveal
        state.cameraX += state.cameraSpeed * deltaTime

        // 4.6.3) Baseline player motion
        if !state.isIdleForcedByTap {
            let dir: Double = (state.playerFacing == .right) ? 1.0 : -1.0
            state.playerX += dir * baseRunSpeed * deltaTime
        }

        // 4.6.4) Vertical physics
        integrateVertical(deltaTime: deltaTime)

        // 4.6.5) Clamp player into camera-relative window
        let wasClamped = clampPlayerToCameraWindow()

        // 4.6.6) Derive room strip position (authoritative) BEFORE puppy so we can keep the puppy in the same room.
        updateCurrentRoom()

        // 4.6.7) Puppy: ensure spawned, then update deterministic behavior
        spawnActivePuppyIfNeeded()
        updateActivePuppy(deltaTime: deltaTime)

        // 4.6.8) Constrain puppy to the same room AND the revealed camera window (doorless v1).
        //        This prevents "warp" when the player crosses room seams and makes the puppy obey the
        //        same revealed-boundary rules as the player (dragged forward on the left, restricted on the right).
        clampActivePuppyToCameraWindow()

        // 4.6.9) Capture check (distance-based in world-space; jumping avoids capture naturally)
        evaluateCapture()

        // 4.6.10) Derive facing from movement delta (unless clamped)
        let dx = state.playerX - previousPlayerX
        if abs(dx) > 0.0001 && !wasClamped {
            updateFacing(from: dx)
        }

        // 4.6.11) Derive minimal player anim state
        updateAnim(previousPlayerX: previousPlayerX)
    }

    // -------------------------------------------------------------------------
    // Section 5: Input application
    // -------------------------------------------------------------------------
    func apply(inputEvents: [InputEvent]) {
        guard !inputEvents.isEmpty else { return }

        for event in inputEvents {
            switch event {
            case .togglePause:
                continue

            case .swipeLeft:
                if state.isIdleForcedByTap {
                    state.isIdleForcedByTap = false
                    state.cameraSpeed = defaultCameraSpeed
                }
                state.playerFacing = .left
                state.playerX -= impulseDistance

            case .swipeRight:
                if state.isIdleForcedByTap {
                    state.isIdleForcedByTap = false
                    state.cameraSpeed = defaultCameraSpeed
                }
                state.playerFacing = .right
                state.playerX += impulseDistance

            case .swipeUp:
                if isGrounded() {
                    state.playerVY = jumpVelocity
                    GameState.debug("Jump triggered vy=\(jumpVelocity)")
                } else {
                    GameState.debug("Jump ignored (not grounded) y=\(state.playerY) vy=\(state.playerVY)")
                }

            case .swipeDown:
                // Reserved (slide/crouch) - out of scope for now
                break

            case .tapPlayer:
                state.isIdleForcedByTap = true
                GameState.debug("Tap stop triggered: cameraSpeed=0")
            }
        }
    }

    // -------------------------------------------------------------------------
    // Section 6: Player physics helpers
    // -------------------------------------------------------------------------
    private func integrateVertical(deltaTime: Double) {
        guard !isGrounded() || abs(state.playerVY) > clampEpsilon else { return }

        state.playerVY += gravity * deltaTime
        if state.playerVY < maxFallSpeed { state.playerVY = maxFallSpeed }

        state.playerY += state.playerVY * deltaTime

        if state.playerY <= 0.0 {
            state.playerY = 0.0
            state.playerVY = 0.0
        }
    }

    private func isGrounded() -> Bool {
        return state.playerY <= clampEpsilon && abs(state.playerVY) <= clampEpsilon
    }

    private func clampPlayerToCameraWindow() -> Bool {
        let frontMargin: Double = 60.0
        let minPlayerX = state.cameraX + backMargin
        let maxPlayerX = state.cameraX + state.viewWidth - frontMargin

        let original = state.playerX
        state.playerX = min(max(state.playerX, minPlayerX), maxPlayerX)
        return abs(state.playerX - original) > clampEpsilon
    }

    // -------------------------------------------------------------------------
    // Section 7: Room derivation (authoritative, deterministic)
    // -------------------------------------------------------------------------
    private func updateCurrentRoom() {
        let ids = state.roomIds
        let widths = state.roomWidths

        guard !ids.isEmpty, ids.count == widths.count else { return }

        let loopLength = widths.reduce(0.0, +)
        guard loopLength > 0.0 else { return }

        func positiveModulo(_ x: Double, _ m: Double) -> Double {
            let r = x.truncatingRemainder(dividingBy: m)
            return (r >= 0.0) ? r : (r + m)
        }

        let xInLoop = positiveModulo(state.playerX, loopLength)

        var startOfRoomInLoop = 0.0
        var idx = 0

        for i in 0..<widths.count {
            let w = widths[i]
            if xInLoop < startOfRoomInLoop + w - 1e-9 {
                idx = i
                break
            }
            startOfRoomInLoop += w
            idx = i
        }

        state.currentRoomIndex = idx

        let loopStartX = state.playerX - xInLoop
        state.currentRoomOriginX = loopStartX + startOfRoomInLoop

        if DebugLog.isEnabled, idx != lastRoomIndexLogged {
            lastRoomIndexLogged = idx

            let effectiveViewHeight = state.viewHeight / max(state.viewContentScale, 1.0)
            let oneUnit = state.oneUnitRoomWidth
            let thisWidth = widths[idx]

            DebugLog.log(
                "RoomDerive: idx=\(idx) id=\(ids[idx]) " +
                "playerX=\(state.playerX.rounded()) camX=\(state.cameraX.rounded()) " +
                "originX=\(state.currentRoomOriginX.rounded()) " +
                "viewH=\(state.viewHeight) scale=\(state.viewContentScale) effH=\(effectiveViewHeight) " +
                "oneUnit=\(oneUnit) roomW=\(thisWidth) loopLen=\(loopLength)"
            )

            let minW = widths.min() ?? thisWidth
            let maxW = widths.max() ?? thisWidth
            if (maxW - minW) > 2.0 {
                DebugLog.log("RoomDerive: NOTE roomWidths vary (min=\(minW), max=\(maxW)). Variable-width looping is active.")
            }
        }
    }

    // -------------------------------------------------------------------------
    // Section 7.1: Presentation helpers (player)
    // -------------------------------------------------------------------------
    private func updateFacing(from deltaX: Double) {
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
        if state.isIdleForcedByTap {
            if state.playerAnim != .idle, DebugLog.isEnabled {
                DebugLog.log("playerAnim -> idle (forced by tap)")
            }
            state.playerAnim = .idle
            return
        }

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

    // -------------------------------------------------------------------------
    // Section 8: Puppy system (v1: one active puppy)
    // -------------------------------------------------------------------------

    // Section 8.1: Deterministic PRNG (xorshift64*)
    private func nextRNGUInt64() -> UInt64 {
        // xorshift64* variant
        var x = state.rngState
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        state.rngState = x
        return x &* 2685821657736338717
    }

    private func nextRNGDouble01() -> Double {
        // Convert top 53 bits to a Double in [0,1)
        let u = nextRNGUInt64() >> 11
        return Double(u) / Double(1 << 53)
    }

    // Section 8.2: Per-puppy speed multiplier (v1 tuning)
    private func puppySpeedMultiplier(for puppyId: String) -> Double {
        switch puppyId {
        case "Lilly":
            return 1.05   // slightly faster than player base speed (tunable)
        default:
            return 1.00
        }
    }

    // Section 8.3: Spawn active puppy (deterministic "random" ahead/behind with min spacing)
    private func spawnActivePuppyIfNeeded() {
        guard !state.puppyHasSpawnedThisLevel else { return }

        // Spawn relative to the CURRENTLY VISIBLE window (camera reveal), not room bounds.
        // This avoids loop-seam warping and guarantees the puppy starts on-screen.
        //
        // Contract:
        // - Deterministic "random" chooses ahead vs behind.
        // - Spawn position defaults to the FAR SIDE of the visible window (left or right edge),
        //   and is adjusted to maintain a minimum distance from the player.
        let roll = nextRNGDouble01()
        let spawnAhead = (roll < state.puppySpawnAheadChance)

        // Visible window bounds mirror the player's clamp contract.
        let frontMargin: Double = 60.0
        let camLeft = state.cameraX + backMargin
        let camRight = state.cameraX + state.viewWidth - frontMargin
        guard camRight > camLeft else { return }

        // Keep puppy away from exact screen seams.
        let edgeInset: Double = 40.0
        let leftEdge = camLeft + edgeInset
        let rightEdge = camRight - edgeInset
        guard rightEdge > leftEdge else { return }

        // Default to far side of the window.
        var candidateX = spawnAhead ? rightEdge : leftEdge

        // Add deterministic jitter inward (never past the center by default).
        let jitter = nextRNGDouble01() * max(state.puppySpawnJitter, 0.0)
        if spawnAhead {
            candidateX = max(leftEdge, candidateX - jitter)
        } else {
            candidateX = min(rightEdge, candidateX + jitter)
        }

        // Enforce minimum separation from player; if too close, push to the opposite far edge.
        let minDist = max(state.puppyMinSpawnDistance, 0.0)
        if abs(candidateX - state.playerX) < minDist {
            let opposite = spawnAhead ? leftEdge : rightEdge
            candidateX = opposite
        }

        // Final clamp inside the visible window.
        candidateX = min(max(candidateX, leftEdge), rightEdge)

        state.puppyX = candidateX
        state.puppyY = 0.0
        state.puppyVY = 0.0

        // Reset Lilly decision state; she will pick a direction on first update.
        state.puppyDecisionTimeRemaining = 0.0
        state.puppyDecisionMode = 0
        state.puppyFacing = (state.puppyX < state.playerX) ? .right : .left
        state.puppyAnim = .idle

        state.puppyHasSpawnedThisLevel = true

        if DebugLog.isEnabled {
            DebugLog.log(
                "PuppySpawn: id=\(state.activePuppyId) " +
                "playerX=\(String(format: "%.1f", state.playerX)) " +
                "camX=\(String(format: "%.1f", state.cameraX)) " +
                "spawnAhead=\(spawnAhead) " +
                "puppyX=\(String(format: "%.1f", state.puppyX)) " +
                "win=[\(String(format: "%.1f", leftEdge)),\(String(format: "%.1f", rightEdge))] " +
                "minDist=\(String(format: "%.1f", minDist)) jitter=\(String(format: "%.1f", jitter))"
            )
        }
    }


    // Section 8.4: Update active puppy behavior (Lilly = deterministic random walk; no jumping; no targeting)
    private func updateActivePuppy(deltaTime: Double) {
        // v1: If puppy hasn't spawned yet, do nothing (spawn is handled before this call)
        guard state.puppyHasSpawnedThisLevel else { return }

        switch state.activePuppyId {
        case "Lilly":
            updateLilly(deltaTime: deltaTime)
        default:
            // Safe fallback: behave like Lilly until other puppies are implemented
            updateLilly(deltaTime: deltaTime)
        }
    }

    // Section 8.4.1: Lilly behavior
    private func updateLilly(deltaTime: Double) {
        // Decide segment if needed
        state.puppyDecisionTimeRemaining -= deltaTime
        if state.puppyDecisionTimeRemaining <= 0.0 {
            // Direction: biased toward idle (she's "old/bumbling")
            let r = Int(nextRNGUInt64() % 10)
            if r < 4 {
                state.puppyDecisionMode = 0
            } else if r < 7 {
                state.puppyDecisionMode = -1
            } else {
                state.puppyDecisionMode = 1
            }

            // Duration: 0.6s .. 1.5s
            let duration = 0.6 + (nextRNGDouble01() * 0.9)
            state.puppyDecisionTimeRemaining = duration

            if DebugLog.isEnabled {
                DebugLog.log("LillyDecision: mode=\(state.puppyDecisionMode) duration=\(String(format: "%.2f", duration))")
            }
        }

        // Move horizontally only
        let speed = baseRunSpeed * puppySpeedMultiplier(for: state.activePuppyId)
        let dir = Double(state.puppyDecisionMode)

        _ = state.puppyX
        state.puppyX += dir * speed * deltaTime

        // Facing/anim derived from motion mode
        if state.puppyDecisionMode == 0 {
            state.puppyAnim = .idle
        } else {
            state.puppyAnim = .run
            state.puppyFacing = (state.puppyDecisionMode > 0) ? .right : .left
        }

        //if DebugLog.isEnabled {
        //    let dx = state.puppyX - previousX
        //    if abs(dx) > 0.01 {
        //        DebugLog.log("LillyMove: dx=\(String(format: "%.2f", dx)) puppyX=\(String(format: "%.2f", state.puppyX)) speed=\(String(format: "%.1f", speed))")
        //    }
        //}
    }

    // Section 8.5: Capture evaluation (distance-based)
    

    // Section 10.2: Clamp puppy to the player's current room bounds (v1 doorless)
    //
    // Contract:
    // - The active puppy must remain inside the same logical room as the player.
    // - We use the authoritative player-room origin/width already derived into GameState.
    // - When clamping occurs, Lilly "bounces" by flipping her current decision direction.
    private func clampActivePuppyToCameraWindow() {
        // Clamp the active puppy to the CURRENTLY VISIBLE window (camera reveal).
        // This provides:
        // - "Dragged forward" behavior at the left edge (like the player)
        // - "Revealed boundary" restriction at the right edge (like the player)
        //
        // Importantly, this avoids loop/room seam warping because the bounds are camera-relative.
        let frontMargin: Double = 60.0
        let camLeft = state.cameraX + backMargin
        let camRight = state.cameraX + state.viewWidth - frontMargin
        guard camRight > camLeft else { return }

        let edgeInset: Double = 10.0
        let left = camLeft + edgeInset
        let right = camRight - edgeInset
        guard right > left else { return }

        let originalX = state.puppyX
        let clampedX = min(max(originalX, left), right)
        state.puppyX = clampedX

        // Behavior response for Lilly:
        // - If at the left edge, force rightward movement (she "rides" the reveal).
        // - If at the right edge, force leftward movement.
        if state.activePuppyId == "Lilly" {
            if abs(clampedX - left) < 0.0001 {
                state.puppyDecisionMode = 1
                state.puppyDecisionTimeRemaining = max(state.puppyDecisionTimeRemaining, 0.25)
            } else if abs(clampedX - right) < 0.0001 {
                state.puppyDecisionMode = -1
                state.puppyDecisionTimeRemaining = max(state.puppyDecisionTimeRemaining, 0.25)
            }
        }

        if DebugLog.isEnabled, abs(clampedX - originalX) > 0.0001 {
            DebugLog.log(
                "PuppyClamp(Cam): x \(String(format: "%.1f", originalX)) -> \(String(format: "%.1f", clampedX)) " +
                "win=[\(String(format: "%.1f", left)),\(String(format: "%.1f", right))] camX=\(String(format: "%.1f", state.cameraX))"
            )
        }
    }

private func evaluateCapture() {
        let dx = state.playerX - state.puppyX
        let dy = state.playerY - state.puppyY

        let r = max(state.captureRadius, 0.0)
        let r2 = r * r
        let d2 = (dx * dx) + (dy * dy)

        if d2 <= r2 {
            state.runPhase = .captured
            state.postCaptureTime = 0.0
            state.didJustCaptureThisTick = true

            // Presentation snapshot for the capture moment
            state.playerAnim = .captured
            state.puppyAnim = .lick

            // Freeze camera motion (optional; runPhase gate will prevent further camera advance)
            state.cameraSpeed = 0.0
            state.isIdleForcedByTap = true

            if DebugLog.isEnabled {
                DebugLog.log("CAPTURE: puppy=\(state.activePuppyId) d=\(String(format: "%.2f", sqrt(d2))) r=\(String(format: "%.2f", r)) player=(\(String(format: "%.1f", state.playerX)),\(String(format: "%.1f", state.playerY))) puppy=(\(String(format: "%.1f", state.puppyX)),\(String(format: "%.1f", state.puppyY)))")
            }
        }
    }
}

// End of GameCoreEngine.swift
