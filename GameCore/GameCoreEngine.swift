// File: GameCoreEngine.swift
// GameCoreEngine_20260106-2045.swift
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
    // Section 2.3: Initialization (authoritative defaults)
    // -------------------------------------------------------------------------
    init() {
        // v1: Start at Level 1 with Lilly.
        state.currentLevel = 1
        state.activePuppyId = "Lilly"
        state.levelBannerTimeRemaining = 2.0
    }

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


        // Sadie+ jump state is shared across puppies; reset on identity change to avoid inheriting cooldowns.
        state.puppyJumpCooldownTimeRemaining = 0.0

        // Georgia cute-pull timers are level-scoped; reset on identity change.
        state.georgiaCutePullCooldownRemaining = 0.0
        state.georgiaCutePullTimeRemaining = 0.0
        state.georgiaCutePullConfiguredDuration = georgiaCutePullDuration
    }

    // -------------------------------------------------------------------------
    // Section 2.3.1: Run control (authoritative)
    // -------------------------------------------------------------------------
    /// Resets the entire run back to Level 1 (score/time cleared).
    /// Runtime should call this for "Play Again" and when changing characters.
    func resetRun(activePlayerId: String, startingLevel: Int = 1) {
        // Preserve view sizing fields owned by the runtime.
        let preservedViewWidth = state.viewWidth
        let preservedViewHeight = state.viewHeight
        state = GameState()
        state.viewWidth = preservedViewWidth
        state.viewHeight = preservedViewHeight
        // viewContentScale is runtime-owned but room sizing uses points; keep default 1.0 on reset for determinism.
        state.viewContentScale = 1.0

        let clampedStartLevel = max(1, min(startingLevel, puppyOrder.count))
        state.currentLevel = clampedStartLevel
        state.activePuppyId = puppyId(forLevel: clampedStartLevel)
        state.levelBannerTimeRemaining = levelBannerDuration
        state.activePlayerId = activePlayerId

        // Ensure puppy will re-spawn deterministically.
        state.puppyHasSpawnedThisLevel = false
        state.puppyDecisionTimeRemaining = 0.0
        state.puppyDecisionMode = 0

        if DebugLog.isEnabled {
            DebugLog.log("GameCoreEngine.resetRun(activePlayerId=\(activePlayerId)) -> Level 1 (\(state.activePuppyId))")
        }
    }

    /// Restarts a run at the most recently achieved level (score/time cleared).
    /// Runtime should call this for "Play Again" when the player wants to retry the current level
    /// without going back to Level 1.
    func restartFromMostRecentLevel(activePlayerId: String) {
        // Preserve view sizing fields owned by the runtime.
        let preservedViewWidth = state.viewWidth
        let preservedViewHeight = state.viewHeight

        // Preserve the most recently achieved level (clamped to valid range).
        let preservedLevel = min(max(state.currentLevel, 1), state.maxLevel)

        state = GameState()
        state.viewWidth = preservedViewWidth
        state.viewHeight = preservedViewHeight
        // viewContentScale is runtime-owned but room sizing uses points; keep default 1.0 on reset for determinism.
        state.viewContentScale = 1.0

        // Restart at the preserved level, but clear cumulative metrics.
        state.currentLevel = preservedLevel
        state.activePuppyId = puppyId(forLevel: preservedLevel)
        state.levelBannerTimeRemaining = levelBannerDuration
        state.activePlayerId = activePlayerId

        state.score = 0
        state.scoreRemainder = 0.0
        state.elapsedTime = 0.0
        state.elapsedLevelTime = 0.0

        // Clear capture/phase state
        state.runPhase = .playing
        state.postCaptureTime = 0.0
        state.didJustCaptureThisTick = false

        // Ensure puppy will re-spawn deterministically.
        state.puppyHasSpawnedThisLevel = false
        state.puppyDecisionTimeRemaining = 0.0
        state.puppyDecisionMode = 0
        state.puppyJumpCooldownTimeRemaining = 0.0

        // Georgia cute-pull timers are level-scoped; reset on restart.
        state.georgiaCutePullCooldownRemaining = 0.0
        state.georgiaCutePullTimeRemaining = 0.0
        state.georgiaCutePullConfiguredDuration = georgiaCutePullDuration

        if DebugLog.isEnabled {
            DebugLog.log("GameCoreEngine.restartFromMostRecentLevel(activePlayerId=\(activePlayerId)) -> Level \(state.currentLevel) (\(state.activePuppyId)) score reset to 0")
        }
    }


    /// Advances to the next level while preserving score and overall elapsedTime.
    /// Called automatically after capture to keep the run going (survival scoring).
    func advanceToNextLevelAfterCapture() {
        // Preserve cumulative metrics
        let preservedScore = state.score

        // Level cap gate (v1): do not advance past maxLevel.
        guard state.currentLevel < state.maxLevel else {
            if DebugLog.isEnabled {
                DebugLog.log("AdvanceLevel: at cap level=\(state.currentLevel)/\(state.maxLevel) (no-op)")
            }
            return
        }
        let preservedScoreRemainder = state.scoreRemainder
        let preservedElapsedTime = state.elapsedTime

        // Increment level
        state.currentLevel += 1
        let nextPuppyId = puppyId(forLevel: state.currentLevel)

        // Reset level-scoped state
        state.runPhase = .playing
        state.postCaptureTime = 0.0
        state.didJustCaptureThisTick = false

        state.elapsedLevelTime = 0.0
        state.levelBannerTimeRemaining = levelBannerDuration

        state.isIdleForcedByTap = false
        state.cameraSpeed = defaultCameraSpeed

        state.playerAnim = .idle
        state.puppyAnim = .idle

        // Swap puppy identity + force re-spawn on next tick.
        setActivePuppyId(nextPuppyId)
        state.puppyHasSpawnedThisLevel = false

        // Restore cumulative metrics
        state.score = preservedScore
        state.scoreRemainder = preservedScoreRemainder
        state.elapsedTime = preservedElapsedTime

        if DebugLog.isEnabled {
            DebugLog.log("AdvanceLevel: level=\(state.currentLevel) puppy=\(state.activePuppyId) score=\(state.score)")
        }
    }

    // Section 2.3.2: Level-to-puppy mapping (v1)
    private func puppyId(forLevel level: Int) -> String {
        // v1: exactly one puppy per level (1-based). If level exceeds list, clamp to last.
        let idx = max(0, level - 1)
        if idx < puppyOrder.count { return puppyOrder[idx] }
        return puppyOrder.last ?? "Molly"
    }


    // -------------------------------------------------------------------------
    // Section 3: Tunables (deterministic constants)
    // -------------------------------------------------------------------------
    // Player
    private let baseRunSpeed: Double = 180.0          // points/sec (player baseline)
    private let defaultCameraSpeed: Double = 120.0    // points/sec (camera baseline)
    private let impulseDistance: Double = 60.0        // points per swipe


    // Level/puppy progression (v1 survival: levels advance on capture)
    private let levelBannerDuration: Double = 2.0
    private let puppyOrder: [String] = ["Lilly", "Molly", "Sadie", "Violet", "Georgia"] // v1 levels 1-5 (one puppy per level)

    // Jump (player)
    private let jumpVelocity: Double = 900.0          // points/sec

    // Gravity (shared)
    private let gravity: Double = -2400.0             // points/sec^2
    private let maxFallSpeed: Double = -3000.0        // points/sec
    private let clampEpsilon: Double = 0.0001

    // Jump (puppy: Sadie+)
    // Sadie jumps are intentionally imperfect: randomized timing and slightly variable takeoff velocity.
    private let sadieBaseJumpVelocity: Double = 820.0 // points/sec
    private let sadieJumpVelocityJitterPct: Double = 0.22 // +/-22%
    private let sadieJumpAttemptChance: Double = 0.65 // when cooldown expires and grounded
    private let sadieJumpCooldownMin: Double = 0.70
    private let sadieJumpCooldownMax: Double = 2.10
    private let sadieNoJumpRetryMin: Double = 0.20
    private let sadieNoJumpRetryMax: Double = 0.55

    // Jump (puppy: Violet)
    // Violet jumps are accurate and efficient (less randomness than Sadie).
    private let violetBaseJumpVelocity: Double = 850.0 // points/sec
    private let violetJumpVelocityJitterPct: Double = 0.10 // +/-10%
    private let violetJumpAttemptChance: Double = 0.80
    private let violetJumpCooldownMin: Double = 0.55
    private let violetJumpCooldownMax: Double = 1.40
    private let violetNoJumpRetryMin: Double = 0.18
    private let violetNoJumpRetryMax: Double = 0.40

    // Jump (puppy: Georgia)
    // Georgia jumps are efficient and reliable (low variance) compared to Sadie/Violet.
    private let georgiaBaseJumpVelocity: Double = 860.0 // points/sec
    private let georgiaJumpVelocityJitterPct: Double = 0.08 // +/-8%
    private let georgiaJumpAttemptChance: Double = 0.85
    private let georgiaJumpCooldown: Double = 0.75 // seconds (fixed, per user request)
    private let georgiaNoJumpRetry: Double = 0.20   // seconds (fixed)

    // Georgia cute pull (Level 5)
    // User-locked tuning: cooldown=6.0s, duration=0.7s, strength=100 points/sec.
    private let georgiaCutePullCooldown: Double = 6.0
    private let georgiaCutePullDuration: Double = 0.7
    private let georgiaCutePullStrength: Double = 100.0

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


        // Section 4.3.1: Level banner countdown (snapshot-only UI)
        if state.levelBannerTimeRemaining > 0.0 {
            state.levelBannerTimeRemaining = max(0.0, state.levelBannerTimeRemaining - deltaTime)
        }

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

        // 4.6.7.1) Puppy vertical physics (Sadie+). Lilly/Molly remain grounded.
        integratePuppyVertical(deltaTime: deltaTime)

        // 4.6.8) Constrain puppy to the same room AND the revealed camera window (doorless v1).
        //        This prevents "warp" when the player crosses room seams and makes the puppy obey the
        //        same revealed-boundary rules as the player (dragged forward on the left, restricted on the right).
        clampActivePuppyToCameraWindow()

        // 4.6.8.1) Georgia (Level 5): periodically apply a deterministic horizontal "cute pull"
        //          that biases the player toward Georgia.
        applyGeorgiaCutePull(deltaTime: deltaTime)

        // Re-apply camera window clamp and room derivation after pull.
        _ = clampPlayerToCameraWindow()
        updateCurrentRoom()

        // 4.6.9) Capture check (distance-based in world-space; jumping avoids capture naturally)
        evaluateCapture()

        // 4.6.9.1) If capture occurred this tick, preserve captured presentation and skip facing/anim derivations.
        if state.runPhase == .captured {
            return
        }

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

            case .swipeUpLeft:
                // Diagonal jump: set facing immediately and jump if grounded.
                // Horizontal motion will be applied by the baseline movement system at baseRunSpeed.
                if state.isIdleForcedByTap {
                    state.isIdleForcedByTap = false
                    state.cameraSpeed = defaultCameraSpeed
                }
                state.playerFacing = .left
                if isGrounded() {
                    state.playerVY = jumpVelocity
                    GameState.debug("Jump (up-left) triggered vy=\(jumpVelocity)")
                } else {
                    GameState.debug("Jump (up-left) ignored (not grounded) y=\(state.playerY) vy=\(state.playerVY)")
                }

            case .swipeUpRight:
                // Diagonal jump: set facing immediately and jump if grounded.
                // Horizontal motion will be applied by the baseline movement system at baseRunSpeed.
                if state.isIdleForcedByTap {
                    state.isIdleForcedByTap = false
                    state.cameraSpeed = defaultCameraSpeed
                }
                state.playerFacing = .right
                if isGrounded() {
                    state.playerVY = jumpVelocity
                    GameState.debug("Jump (up-right) triggered vy=\(jumpVelocity)")
                } else {
                    GameState.debug("Jump (up-right) ignored (not grounded) y=\(state.playerY) vy=\(state.playerVY)")
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


    // Section 6.1.1: Puppy vertical physics helpers (Sadie+)
    private func integratePuppyVertical(deltaTime: Double) {
        guard !isPuppyGrounded() || abs(state.puppyVY) > clampEpsilon else { return }

        state.puppyVY += gravity * deltaTime
        if state.puppyVY < maxFallSpeed { state.puppyVY = maxFallSpeed }

        state.puppyY += state.puppyVY * deltaTime

        if state.puppyY <= 0.0 {
            state.puppyY = 0.0
            state.puppyVY = 0.0
        }
    }

    private func isPuppyGrounded() -> Bool {
        return state.puppyY <= clampEpsilon && abs(state.puppyVY) <= clampEpsilon
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
    // Contract:
    // - Base puppy tuning multiplier per puppy personality
    // - Multiplied by the global time-based ramp:
    //     +10% at 60s, then +10% every 10s thereafter (infinite)
    private func puppySpeedMultiplier(for puppyId: String) -> Double {
        let base: Double
        switch puppyId {
        case "Lilly":
            base = 1.05   // slightly faster than player baseline (tunable)
        case "Molly":
            base = 1.10   // capable ground chaser (tunable)
        case "Sadie":
            base = 1.16   // user request: a bit faster than Molly (tunable)
        case "Violet":
            base = 1.22   // placeholder until Violet personality is implemented
        case "Georgia":
            base = 1.25   // placeholder until Georgia personality is implemented
        default:
            base = 1.00
        }
        return base * globalPuppyRampMultiplier(elapsedLevelTime: state.elapsedLevelTime)
    }

    // Section 8.2.1: Global time-based puppy speed ramp (infinite)
    // +10% after the first minute, then +10% every 10 seconds after that.
    private func globalPuppyRampMultiplier(elapsedLevelTime: Double) -> Double {
        guard elapsedLevelTime >= 60.0 else { return 1.0 }
        let steps = Int(floor((elapsedLevelTime - 60.0) / 10.0)) + 1
        return 1.0 + (Double(steps) * 0.10)
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

        case "Molly":
            updateMolly(deltaTime: deltaTime)

        case "Sadie":
            updateSadie(deltaTime: deltaTime)

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

    
    // Section 8.4.2: Molly behavior
    // v1 personality:
    // - Ground-only (no jumping)
    // - Targets the player with imperfect directional correction (deterministic noise)
    // - Less idle than Lilly
    private func updateMolly(deltaTime: Double) {
        // Decide segment if needed
        state.puppyDecisionTimeRemaining -= deltaTime
        if state.puppyDecisionTimeRemaining <= 0.0 {
            // Determine the "desired" direction toward the player.
            let toward: Int
            if state.playerX > state.puppyX + 1.0 {
                toward = 1
            } else if state.playerX < state.puppyX - 1.0 {
                toward = -1
            } else {
                toward = 0
            }

            // Molly: mostly correct, occasionally wrong/idle.
            // r in [0,9]
            let r = Int(nextRNGUInt64() % 10)
            if r == 0 {
                state.puppyDecisionMode = 0                 // brief idle
            } else if r <= 7 {
                state.puppyDecisionMode = toward == 0 ? 0 : toward  // usually toward player
            } else {
                state.puppyDecisionMode = (toward == 0) ? 0 : -toward // occasionally wrong
            }

            // Duration: 0.35s .. 0.95s (more responsive than Lilly)
            let duration = 0.35 + (nextRNGDouble01() * 0.60)
            state.puppyDecisionTimeRemaining = duration

            if DebugLog.isEnabled {
                DebugLog.log("MollyDecision: mode=\(state.puppyDecisionMode) toward=\(toward) duration=\(String(format: "%.2f", duration))")
            }
        }

        // Move horizontally only
        let speed = baseRunSpeed * puppySpeedMultiplier(for: state.activePuppyId)
        let dir = Double(state.puppyDecisionMode)

        state.puppyX += dir * speed * deltaTime

        // Facing/anim derived from motion mode
        if state.puppyDecisionMode == 0 {
            state.puppyAnim = .idle
        } else {
            state.puppyAnim = .run
            state.puppyFacing = (state.puppyDecisionMode > 0) ? .right : .left
        }
    }

// Section 8.5: Capture evaluation (distance-based)


    // Section 8.4.3: Sadie behavior
    // v1 personality:
    // - Can jump (random timing)
    // - Slightly faster than Molly (per tuning in puppySpeedMultiplier)
    // - Jumps are imperfect/over-eager (often jumps when not needed)
    private func updateSadie(deltaTime: Double) {
        // Horizontal targeting similar to Molly, but more "excited" (less idle).
        state.puppyDecisionTimeRemaining -= deltaTime
        if state.puppyDecisionTimeRemaining <= 0.0 {
            let toward: Int
            if state.playerX > state.puppyX + 1.0 {
                toward = 1
            } else if state.playerX < state.puppyX - 1.0 {
                toward = -1
            } else {
                toward = 0
            }

            // Sadie: usually toward, sometimes wrong, rarely idle.
            let r = Int(nextRNGUInt64() % 20) // 0..19
            if r == 0 {
                state.puppyDecisionMode = 0
            } else if r <= 15 {
                state.puppyDecisionMode = toward == 0 ? 0 : toward
            } else {
                state.puppyDecisionMode = (toward == 0) ? 0 : -toward
            }

            // Duration: 0.25s .. 0.75s (very reactive)
            let duration = 0.25 + (nextRNGDouble01() * 0.50)
            state.puppyDecisionTimeRemaining = duration

            if DebugLog.isEnabled {
                DebugLog.log("SadieDecision: mode=\(state.puppyDecisionMode) toward=\(toward) duration=\(String(format: "%.2f", duration))")
            }
        }

        // Random jumps (deterministic via GameCore RNG).
        // Contract: when grounded and cooldown expires, Sadie may jump. Jump timing is not obstacle-driven in v1.
        state.puppyJumpCooldownTimeRemaining = max(0.0, state.puppyJumpCooldownTimeRemaining - deltaTime)

        if isPuppyGrounded() && state.puppyJumpCooldownTimeRemaining <= 0.0 {
            let roll = nextRNGDouble01()
            if roll < sadieJumpAttemptChance {
                // Apply a jittered takeoff velocity to create "imperfect" jump profiles.
                let jitter = (nextRNGDouble01() * 2.0 - 1.0) * sadieJumpVelocityJitterPct
                let vy = sadieBaseJumpVelocity * (1.0 + jitter)

                state.puppyVY = vy

                // New cooldown after a successful jump
                let cd = sadieJumpCooldownMin + (nextRNGDouble01() * (sadieJumpCooldownMax - sadieJumpCooldownMin))
                state.puppyJumpCooldownTimeRemaining = cd

                if DebugLog.isEnabled {
                    DebugLog.log("SadieJump: roll=\(String(format: "%.2f", roll)) vy=\(String(format: "%.1f", vy)) cooldown=\(String(format: "%.2f", cd))")
                }
            } else {
                // Short retry cooldown so we don't roll every tick
                let retry = sadieNoJumpRetryMin + (nextRNGDouble01() * (sadieNoJumpRetryMax - sadieNoJumpRetryMin))
                state.puppyJumpCooldownTimeRemaining = retry

                if DebugLog.isEnabled {
                    DebugLog.log("SadieJumpSkip: roll=\(String(format: "%.2f", roll)) retryIn=\(String(format: "%.2f", retry))")
                }
            }
        }

        // Horizontal movement (continues while airborne).
        let speed = baseRunSpeed * puppySpeedMultiplier(for: state.activePuppyId)
        let dir = Double(state.puppyDecisionMode)
        state.puppyX += dir * speed * deltaTime

        // Facing/anim derived from motion mode (no distinct jump anim in v1).
        if state.puppyDecisionMode == 0 {
            state.puppyAnim = .idle
        } else {
            state.puppyAnim = .run
            state.puppyFacing = (state.puppyDecisionMode > 0) ? .right : .left
        }
    }




// Section 8.4.4: Violet behavior (Level 4)
// v1 personality:
// - Fast
// - Can jump
// - Jumps are accurate (less randomness than Sadie; tighter cooldowns; lower jitter)
private func updateViolet(deltaTime: Double) {
    // Horizontal targeting similar to Sadie, but with less idle and fewer wrong-direction decisions.
    state.puppyDecisionTimeRemaining -= deltaTime
    if state.puppyDecisionTimeRemaining <= 0.0 {
        let toward: Int
        if state.playerX > state.puppyX + 1.0 {
            toward = 1
        } else if state.playerX < state.puppyX - 1.0 {
            toward = -1
        } else {
            toward = 0
        }

        // Violet: almost always correct, occasionally wrong, rarely idle.
        let r = Int(nextRNGUInt64() % 30) // 0..29
        if r == 0 {
            state.puppyDecisionMode = 0
        } else if r <= 25 {
            state.puppyDecisionMode = toward == 0 ? 0 : toward
        } else {
            state.puppyDecisionMode = (toward == 0) ? 0 : -toward
        }

        // Duration: 0.22s .. 0.62s (reactive, but not jittery)
        let duration = 0.22 + (nextRNGDouble01() * 0.40)
        state.puppyDecisionTimeRemaining = duration

        if DebugLog.isEnabled {
            DebugLog.log("VioletDecision: mode=\(state.puppyDecisionMode) toward=\(toward) duration=\(String(format: "%.2f", duration))")
        }
    }

    // Accurate jumps (deterministic via GameCore RNG).
    state.puppyJumpCooldownTimeRemaining = max(0.0, state.puppyJumpCooldownTimeRemaining - deltaTime)

    if isPuppyGrounded() && state.puppyJumpCooldownTimeRemaining <= 0.0 {
        let roll = nextRNGDouble01()
        if roll < violetJumpAttemptChance {
            let jitter = (nextRNGDouble01() * 2.0 - 1.0) * violetJumpVelocityJitterPct
            let vy = violetBaseJumpVelocity * (1.0 + jitter)
            state.puppyVY = vy

            let cd = violetJumpCooldownMin + (nextRNGDouble01() * (violetJumpCooldownMax - violetJumpCooldownMin))
            state.puppyJumpCooldownTimeRemaining = cd

            if DebugLog.isEnabled {
                DebugLog.log("VioletJump: roll=\(String(format: "%.2f", roll)) vy=\(String(format: "%.1f", vy)) cooldown=\(String(format: "%.2f", cd))")
            }
        } else {
            let retry = violetNoJumpRetryMin + (nextRNGDouble01() * (violetNoJumpRetryMax - violetNoJumpRetryMin))
            state.puppyJumpCooldownTimeRemaining = retry

            if DebugLog.isEnabled {
                DebugLog.log("VioletJumpSkip: roll=\(String(format: "%.2f", roll)) retryIn=\(String(format: "%.2f", retry))")
            }
        }
    }

    // Horizontal movement (continues while airborne).
    let speed = baseRunSpeed * puppySpeedMultiplier(for: state.activePuppyId)
    let dir = Double(state.puppyDecisionMode)
    state.puppyX += dir * speed * deltaTime

    if state.puppyDecisionMode == 0 {
        state.puppyAnim = .idle
    } else {
        state.puppyAnim = .run
        state.puppyFacing = (state.puppyDecisionMode > 0) ? .right : .left
    }
}


// Section 8.4.5: Georgia behavior (Level 5)
// v1 personality:
// - Fast
// - Can jump
// - Periodically applies a deterministic horizontal "cute pull" toward herself (handled in applyGeorgiaCutePull)
// - Minimal hesitation; very accurate movement and jumping
private func updateGeorgia(deltaTime: Double) {
    // Horizontal targeting similar to Violet, but with even less idle and fewer wrong-direction decisions.
    state.puppyDecisionTimeRemaining -= deltaTime
    if state.puppyDecisionTimeRemaining <= 0.0 {
        let toward: Int
        if state.playerX > state.puppyX + 1.0 {
            toward = 1
        } else if state.playerX < state.puppyX - 1.0 {
            toward = -1
        } else {
            toward = 0
        }

        // Georgia: overwhelmingly correct direction, very rarely idle or wrong.
        let r = Int(nextRNGUInt64() % 40) // 0..39
        if r == 0 {
            state.puppyDecisionMode = 0 // rare idle
        } else if r <= 36 {
            state.puppyDecisionMode = toward == 0 ? 0 : toward
        } else {
            state.puppyDecisionMode = (toward == 0) ? 0 : -toward // rare wrong
        }

        // Duration: 0.20s .. 0.55s (high responsiveness)
        let duration = 0.20 + (nextRNGDouble01() * 0.35)
        state.puppyDecisionTimeRemaining = duration

        if DebugLog.isEnabled {
            DebugLog.log("GeorgiaDecision: mode=\(state.puppyDecisionMode) toward=\(toward) duration=\(String(format: "%.2f", duration))")
        }
    }

    // Reliable jumps (deterministic).
    state.puppyJumpCooldownTimeRemaining = max(0.0, state.puppyJumpCooldownTimeRemaining - deltaTime)

    if isPuppyGrounded() && state.puppyJumpCooldownTimeRemaining <= 0.0 {
        let roll = nextRNGDouble01()
        if roll < georgiaJumpAttemptChance {
            let jitter = (nextRNGDouble01() * 2.0 - 1.0) * georgiaJumpVelocityJitterPct
            let vy = georgiaBaseJumpVelocity * (1.0 + jitter)
            state.puppyVY = vy

            // Fixed cooldown (user-locked).
            state.puppyJumpCooldownTimeRemaining = georgiaJumpCooldown

            if DebugLog.isEnabled {
                DebugLog.log("GeorgiaJump: roll=\(String(format: "%.2f", roll)) vy=\(String(format: "%.1f", vy)) cooldown=\(String(format: "%.2f", georgiaJumpCooldown))")
            }
        } else {
            // Fixed retry delay so we don't roll every tick.
            state.puppyJumpCooldownTimeRemaining = georgiaNoJumpRetry

            if DebugLog.isEnabled {
                DebugLog.log("GeorgiaJumpSkip: roll=\(String(format: "%.2f", roll)) retryIn=\(String(format: "%.2f", georgiaNoJumpRetry))")
            }
        }
    }

    // Horizontal movement (continues while airborne).
    let speed = baseRunSpeed * puppySpeedMultiplier(for: state.activePuppyId)
    let dir = Double(state.puppyDecisionMode)
    state.puppyX += dir * speed * deltaTime

    if state.puppyDecisionMode == 0 {
        state.puppyAnim = .idle
    } else {
        state.puppyAnim = .run
        state.puppyFacing = (state.puppyDecisionMode > 0) ? .right : .left
    }

    // Initialize Georgia cute-pull cadence on first tick after spawn.
    if state.georgiaCutePullCooldownRemaining <= 0.0 && state.georgiaCutePullTimeRemaining <= 0.0 {
        state.georgiaCutePullCooldownRemaining = georgiaCutePullCooldown
    }
}

// Section 8.4.6: Georgia cute pull application (player bias)
// Contract:
// - When Georgia is active, a pull window periodically activates.
// - During the pull window, playerX is biased toward puppyX at a fixed rate (points/sec).
// - All effects remain deterministic and are clamped by the existing camera-window rules.
private func applyGeorgiaCutePull(deltaTime: Double) {
    guard state.activePuppyId == "Georgia" else { return }
    guard state.puppyHasSpawnedThisLevel else { return }

    // Countdown existing timers
    if state.georgiaCutePullCooldownRemaining > 0.0 {
        state.georgiaCutePullCooldownRemaining = max(0.0, state.georgiaCutePullCooldownRemaining - deltaTime)
    }
    if state.georgiaCutePullTimeRemaining > 0.0 {
        state.georgiaCutePullTimeRemaining = max(0.0, state.georgiaCutePullTimeRemaining - deltaTime)
    }

    // Start a new pull window when cooldown expires and we are not already pulling.
    if state.georgiaCutePullCooldownRemaining <= 0.0 && state.georgiaCutePullTimeRemaining <= 0.0 {
        state.georgiaCutePullTimeRemaining = georgiaCutePullDuration
        state.georgiaCutePullConfiguredDuration = georgiaCutePullDuration
        state.georgiaCutePullCooldownRemaining = georgiaCutePullCooldown

        if DebugLog.isEnabled {
            DebugLog.log("GeorgiaCutePullStart: duration=\(String(format: "%.2f", georgiaCutePullDuration)) cooldown=\(String(format: "%.2f", georgiaCutePullCooldown)) strength=\(String(format: "%.1f", georgiaCutePullStrength))")
        }
    }

    // Apply pull if active
    guard state.georgiaCutePullTimeRemaining > 0.0 else { return }

    let dx = state.puppyX - state.playerX
    if abs(dx) < 0.0001 { return }

    let dir: Double = dx > 0 ? 1.0 : -1.0
    let delta = dir * georgiaCutePullStrength * deltaTime
    state.playerX += delta

    if DebugLog.isEnabled {
        DebugLog.log("GeorgiaCutePullApply: playerX+=\(String(format: "%.2f", delta)) playerX=\(String(format: "%.1f", state.playerX)) puppyX=\(String(format: "%.1f", state.puppyX)) remaining=\(String(format: "%.2f", state.georgiaCutePullTimeRemaining))")
    }
}

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
            // Special rule (Sadie+): if contact occurs while either entity is airborne, snap both to ground immediately
            // and treat as an immediate capture. Rendering will show the captured/lick states from ground level.
            if state.playerY > clampEpsilon || state.puppyY > clampEpsilon {
                if DebugLog.isEnabled {
                    DebugLog.log("CAPTURE_MIDAIR: playerY=\(String(format: "%.1f", state.playerY)) puppyY=\(String(format: "%.1f", state.puppyY)) -> snapping to ground")
                }
                state.playerY = 0.0
                state.playerVY = 0.0
                state.puppyY = 0.0
                state.puppyVY = 0.0
            }

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
