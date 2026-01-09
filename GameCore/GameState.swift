// File: GameState.swift
// GameState_20260106-2045.swift
// Purpose: Defines the authoritative, deterministic simulation state for Running From Puppies (GameCore).
//          Rendering consumes immutable snapshots of this state and must never mutate it.
//          This file is the single source of truth for simulation data (player, camera, rooms, active puppy, scoring, run phase).
//
// Sections:
// 1. Imports
// 2. Presentation Enums (snapshot-only)
// 3. Run / Puppy Enums (authoritative + snapshot)
// 4. GameState (authoritative simulation state)
// 5. Debug Logging (default Off)
//
// NOTE: Debug output is controlled by GameState.debugEnabled (default Off). When enabled, logs write to a temp file.
//
// End-of-file marker is included at the bottom.

// Section 1: Imports
import Foundation

// Section 2: Presentation Enums (snapshot-only)
enum PlayerFacing: String, Codable {
    case left
    case right
}

enum PlayerAnim: String, Codable {
    case idle
    case run
    case captured   // v1: shown after puppy capture (player "lick reaction" / defeated pose)
}

// Section 3: Run / Puppy Enums (authoritative + snapshot)
enum RunPhase: String, Codable {
    case playing
    case captured
}

enum PuppyAnim: String, Codable {
    case idle
    case run
    case lick
}

// Section 4: GameState
struct GameState {
    // -------------------------------------------------------------------------
    // 4.1 Scoring (authoritative)
    // -------------------------------------------------------------------------
    var score: Int = 0
    var scoreRemainder: Double = 0

    // -------------------------------------------------------------------------
    // 4.2 Debug Controls (default Off)
    // -------------------------------------------------------------------------
    static var debugEnabled: Bool = false
    static var debugLogURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("RunningFromPuppies_Debug.log")

    // -------------------------------------------------------------------------
    // 4.3 Core simulation: Player (authoritative)
    // -------------------------------------------------------------------------
    // Player horizontal position in world space (points)
    var playerX: Double = 0.0

    // Player vertical offset from ground plane in world space (points).
    // 0.0 means feet are on the ground. Positive values move the player upward.
    var playerY: Double = 0.0

    // Player vertical velocity in world space (points/second).
    var playerVY: Double = 0.0

    // World time since app start (seconds)
    var elapsedTime: Double = 0.0

    // Level time since current level/run start (seconds)
    var elapsedLevelTime: Double = 0.0

    // Pause state (authoritative)
    var isPaused: Bool = false

    // -------------------------------------------------------------------------
    // 4.4 Run lifecycle (authoritative)
    // -------------------------------------------------------------------------
    // v1: Level ends on capture. We keep a short deterministic post-capture window
    // for lick/captured animation before the runtime transitions to the next level.
    var runPhase: RunPhase = .playing
    var postCaptureTime: Double = 0.0
    var postCaptureDuration: Double = 1.0   // seconds (tunable)
    var didJustCaptureThisTick: Bool = false

    // -------------------------------------------------------------------------
    // 4.4.1 Level progression (authoritative)
    // -------------------------------------------------------------------------
    // Current level number (1-based). Level advances automatically when the active puppy captures the player.
    var currentLevel: Int = 1

    // Cap for v1 progression.
    var maxLevel: Int = 5

    // Short banner shown at the start of each level (seconds remaining).
    // Rendering may show "Level N - PuppyName" while this is > 0.
    var levelBannerTimeRemaining: Double = 0.0

    // -------------------------------------------------------------------------
    // 4.5 Camera/world model (authoritative)
    // -------------------------------------------------------------------------
    // cameraX is the left edge of the visible window in world space.
    var cameraX: Double = 0.0

    // Width/height of visible window (points). Runtime/UI should set these from actual view size.
    var viewWidth: Double = 390.0
    var viewHeight: Double = 844.0

    // Content scale (e.g., UIScreen.main.scale). Used to convert pixel dimensions back to points.
    var viewContentScale: Double = 1.0

    // Constant forward camera speed (points/sec).
    var cameraSpeed: Double = 90.0

    // -------------------------------------------------------------------------
    // 4.6 Room strip model (authoritative)
    // -------------------------------------------------------------------------
    let roomIds: [String] = [
        "Entryway",
        "Parlor",
        "Livingroom",
        "MasterBedroom",
        "Hallway_1",
        "Bedroom_2",
        "JackAndJill",
        "Bedroom_3",
        "Hallway_2",
        "Diningroom",
        "Kitchen",
        "Library"
    ]

    // Artwork sizing contract (pixels)
    private let baseRoomPixelWidthPerUnit: Double = 1536
    private let baseRoomPixelHeight: Double = 1024

    // Room width units (must match roomIds count/order). v1 currently uses 1x rooms.
    private var roomWidthUnits: [Double] {
        [
            1, // Entryway
            1, // Parlor
            1, // Livingroom
            1, // MasterBedroom
            1, // Hallway_1
            1, // Bedroom_2
            1, // JackAndJill
            1, // Bedroom_3
            1, // Hallway_2
            1, // Diningroom
            1, // Kitchen
            1  // Library
        ]
    }

    // Authoritative width of each room in world points (derived from viewHeight and art aspect).
    var roomWidths: [Double] {
        guard viewHeight > 0, baseRoomPixelHeight > 0 else {
            return Array(repeating: 0.0, count: roomIds.count)
        }

        let effectiveViewHeight = viewHeight / max(viewContentScale, 1.0)
        let pxPerUnit = baseRoomPixelWidthPerUnit
        let pxH = baseRoomPixelHeight

        return roomWidthUnits.map { units in
            effectiveViewHeight * ((pxPerUnit * units) / pxH)
        }
    }

    // Convenience: the world-point width of a 1-unit room at the current viewHeight.
    var oneUnitRoomWidth: Double {
        guard viewHeight > 0, baseRoomPixelHeight > 0 else { return 0.0 }
        let effectiveViewHeight = viewHeight / max(viewContentScale, 1.0)
        return effectiveViewHeight * (baseRoomPixelWidthPerUnit / baseRoomPixelHeight)
    }

    // Derived each tick from playerX.
    var currentRoomIndex: Int = 0
    var currentRoomOriginX: Double = 0.0

    // -------------------------------------------------------------------------
    // 4.7 Player presentation selection + state (snapshot-only)
    // -------------------------------------------------------------------------
    var activePlayerId: String = "Finley"
    var hasReceivedUserMovementInput: Bool = true
    var playerFacing: PlayerFacing = .right
    var playerAnim: PlayerAnim = .idle
    var isIdleForcedByTap: Bool = false

    // -------------------------------------------------------------------------
    // 4.8 Puppy system (authoritative; single active puppy in v1)
    // -------------------------------------------------------------------------
    // Generic identity for behavior/asset selection (e.g., "Lilly", "Molly"...)
    var activePuppyId: String = "Lilly"

    // Puppy world-space kinematics
    var puppyX: Double = -200.0
    var puppyY: Double = 0.0
    var puppyVY: Double = 0.0

    // Puppy snapshot presentation
    var puppyFacing: PlayerFacing = .right
    var puppyAnim: PuppyAnim = .idle

    // Deterministic PRNG state (seeded once per level/run; updated deterministically)
    var rngState: UInt64 = 0xC0FFEE_1234_ABCD_56

    // Spawn controls (tunable)
    var puppyHasSpawnedThisLevel: Bool = false
    var puppyMinSpawnDistance: Double = 220.0
    var puppySpawnJitter: Double = 220.0
    var puppySpawnAheadChance: Double = 0.5

    // Capture tuning (world-space distance)
    var captureRadius: Double = 58.0

    // Lilly-style deterministic "random walk" decision segment
    // puppyDecisionMode: -1 = left, 0 = idle, +1 = right
    var puppyDecisionMode: Int = 0
    var puppyDecisionTimeRemaining: Double = 0.0

    // Sadie+ jump behavior state (authoritative, deterministic)
    // puppyJumpCooldownTimeRemaining: when <= 0 and puppy is grounded, AI may initiate a jump (Sadie and later puppies).
    var puppyJumpCooldownTimeRemaining: Double = 0.0

    // Georgia (Level 5) cute-pull behavior timers (authoritative, deterministic)
    // georgiaCutePullCooldownRemaining: counts down to the next pull window.
    // georgiaCutePullTimeRemaining: while > 0, player is pulled horizontally toward Georgia.
    var georgiaCutePullCooldownRemaining: Double = 0.0
    var georgiaCutePullTimeRemaining: Double = 0.0

    // Georgia cute pull: configured duration for rendering the overlay animation (seconds)
    var georgiaCutePullConfiguredDuration: Double = 0.7
}

// Section 5: Debug Logging helper (default Off)
extension GameState {
    static func debug(_ message: String) {
        guard debugEnabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[GameState] \(stamp) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: debugLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: debugLogURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: debugLogURL, options: [.atomic])
            }
        }
    }
}

// End of GameState.swift

