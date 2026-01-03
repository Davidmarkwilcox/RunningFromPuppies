// GameState_20260102-1720.swift
// Defines the authoritative simulation state for Running From Puppies (GameCore). This state is read by rendering and mutated by GameCoreEngine.
//
// Sections:
// 1. Imports
// 2. Types
// 3. Logic
//
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
    // Scoring
    var score: Int = 0
    var scoreRemainder: Double = 0

    // Section 3.0: Debug Controls (default Off)
    //
    // Enable when troubleshooting to emit a lightweight log file in the app's temporary directory.
    // The renderer or UI can surface this file on demand if needed.
    static var debugEnabled: Bool = false
    static var debugLogURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent("RunningFromPuppies_Debug.log")

    static func debug(_ message: String) {
        guard debugEnabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[GameState] \(stamp) \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: debugLogURL.path) {
                if let handle = try? FileHandle(forWritingTo: debugLogURL) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: debugLogURL, options: [.atomic])
            }
        }
    }

    // --- Core simulation ---
    // Player horizontal position in world space (points)
    var playerX: Double = 0.0

    // Player vertical offset from ground plane in world space (points).
    // 0.0 means feet are on the ground. Positive values move the player upward.
    var playerY: Double = 0.0

    // Player vertical velocity in world space (points/second).
    var playerVY: Double = 0.0

    // World time since start (seconds)
    var elapsedTime: Double = 0.0


    // Level time since current level/run start (seconds)
    var elapsedLevelTime: Double = 0.0

    // Pause state (authoritative)
    var isPaused: Bool = false
    // --- MPS-2: Camera/world model (authoritative) ---
    // cameraX is the left edge of the visible window in world space.
    var cameraX: Double = 0.0

    // Width of the visible window (points). Runtime/UI should set this from actual view size.
    var viewWidth: Double = 390.0

    // Height of the visible window (points). Runtime/UI should set this from actual view size.
    // NOTE: Room widths may be derived from this when using "fit height" room art.
    var viewHeight: Double = 844.0

    // Content scale (e.g., UIScreen.main.scale).
    // Set this from the runtime when populating GameState. If your runtime accidentally
    // uses pixel dimensions for viewWidth/viewHeight, set viewContentScale to the device
    // scale to convert back to points for deterministic sizing.
    var viewContentScale: Double = 1.0

    // Constant forward camera speed (points/sec).
    var cameraSpeed: Double = 90.0

    // --- MPS-5: Room strip model (authoritative) ---
    // Deterministic room sequence. Rendering uses these IDs to choose room art.
    // Order is fixed and must not be mutated at runtime.
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

    // Section 3.1: Room width derivation
    //
    // When room art is rendered using "fit height" (height matches the device screen), the
    // effective world width of each room must be derived from the artwork's pixel aspect ratio
    // and the runtime viewHeight.
    //
    // We encode room widths in "units" (1x or 2x) to preserve the design intent (e.g., Entryway
    // is 2 units wide) while still deriving the actual world-point width deterministically.
    //
    // IMPORTANT:
    // - baseRoomPixelHeight must match the master art height you generate (currently 1152 px).
    // - baseRoomPixelWidthPerUnit must match the pixel width that corresponds to 1 unit (currently 1024 px).
    // - A 2-unit room therefore has pixel width 2048 px.
    private let baseRoomPixelWidthPerUnit: Double = 1536
    private let baseRoomPixelHeight: Double = 1024

    // Room width units (must match roomIds count/order). 2x rooms are encoded as 2.0.
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

    // Authoritative width of each room in world points.
    // Rendering uses this for tiling; GameCore uses it to compute current room index/origin.
    //
    // Derived formula (per room): roomWidthPoints = viewHeightPoints * (roomPixelWidth / roomPixelHeight)
    // where roomPixelWidth = baseRoomPixelWidthPerUnit * units.
    var roomWidths: [Double] {
        guard viewHeight > 0, baseRoomPixelHeight > 0 else {
            return Array(repeating: 0.0, count: roomIds.count)
        }

        // Convert to points if runtime provided pixel dimensions.
        let effectiveViewHeight = viewHeight / max(viewContentScale, 1.0)

        // Fit-to-height sizing:
        // widthPoints = viewHeightPoints * (roomPixelWidth / roomPixelHeight)
        // For 1536x1024 art, aspect is 1.5 (3:2).
        let pxPerUnit = baseRoomPixelWidthPerUnit
        let pxH = baseRoomPixelHeight
        return roomWidthUnits.map { units in
            effectiveViewHeight * ((pxPerUnit * units) / pxH)
        }
    }

    // Convenience: the world-point width of a 1-unit room at the current viewHeight.
    // Useful for debugging and future tuning.
    var oneUnitRoomWidth: Double {
        guard viewHeight > 0, baseRoomPixelHeight > 0 else { return 0.0 }

        // Keep sizing math consistent with roomWidths by converting runtime-provided pixel heights
        // back into points when viewContentScale > 1 (retina).
        let effectiveViewHeight = viewHeight / max(viewContentScale, 1.0)
        return effectiveViewHeight * (baseRoomPixelWidthPerUnit / baseRoomPixelHeight)
    }

    // Derived each tick from playerX. 0-based index into roomIds, wrap-safe for infinite rooms.
    var currentRoomIndex: Int = 0

    // Derived each tick: the world-space X origin for the current room tile.
    // Rendering can place the "current" room background at this X.
    var currentRoomOriginX: Double = 0.0
    
    // --- MPS-3: Player presentation selection + state (snapshot-only) ---
    // Active player "skin" identifier used by rendering to pick textures (e.g., "Finley").
    // UI/runtime owns this value; GameCore does not change it.
    var activePlayerId: String = "Finley"

    // Player initially runs.
    var hasReceivedUserMovementInput: Bool = true
    
    // Facing direction for rendering (set deterministically by GameCore from inputs).
    var playerFacing: PlayerFacing = .right

    // Minimal animation state for rendering (set deterministically by GameCore from movement).
    var playerAnim: PlayerAnim = .idle

    // When true, GameCore forces idle + hard stop until a horizontal swipe resumes motion.
    // Rendering consumes this only indirectly via playerAnim/camera/player motion in snapshots.
    var isIdleForcedByTap: Bool = false
}

// End of GameState.swift
// End of GameState_20260102-1720.swift
