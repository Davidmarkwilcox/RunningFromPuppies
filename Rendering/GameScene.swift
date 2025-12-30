// File: GameScene.swift
// Purpose: SpriteKit renderer that consumes immutable GameState snapshots and renders the world (single background per room + player visuals).
// GameScene.swift
// Rendering
// SpriteKit renderer consuming GameState snapshots.
// Rendering must never mutate GameCore state.
//
// This file owns the SpriteKit scene graph for the game runtime. It consumes immutable
// GameState snapshots (from GameCoreEngine) and updates SpriteKit nodes accordingly.
// It may emit InputEvents (e.g., tap on player) via callbacks, but must never mutate
// GameCore state directly.
//
// Section 1: Imports

import SpriteKit
import UIKit

final class GameScene: SKScene {

    // Section 2: Visual cache
    private struct PlayerVisuals {
        let idle: SKTexture
        let runFrames: [SKTexture]
        let runAction: SKAction
    }

    // Section 2.1: Room tile model (single background per room; no paneling)
    // Section 2.1: Room tile model (single background per room; no paneling)
    private struct RoomTile {
        let container: SKNode
        let background: SKSpriteNode   // Full-room background: Room_<RoomId>
        var appliedRoomId: String      // For change detection
    }

    // Section 2.2: Room background cache
    private var roomBackgroundTextureCache: [String: SKTexture?] = [:]
    private var roomBackgroundAspectRatioCache: [String: CGFloat] = [:]  // texWidth/texHeight

    private var visualsCache: [String: PlayerVisuals] = [:]
    private var currentPlayerId: String = ""

    // Section 3: Nodes
    private let playerSprite = SKSpriteNode()

    // Player vertical placement
    // Bottom of sprite sits ~10% above bottom of screen.
    private let playerGroundOffsetRatio: CGFloat = 0.10

    // Section 3.1: Input event sink (Rendering -> Input).
    // GameScene must never mutate GameCore state; it only emits InputEvents.
    var onInputEvent: ((InputEvent) -> Void)?

    // Section 3.2: Rooms (3-room recycler; each room is a single 1536x1024 background image: Room_<RoomId>)
    private let roomsNode = SKNode()
    private let roomTileCount = 3
    private var roomTiles: [RoomTile] = []

    // Section 3.3: Wall tiling (legacy; disabled in single-background pipeline)
    // Wall_1 is kept for reference but is not rendered.
    private let wallNode = SKNode()
    private let wallTileCount = 6  // sized to cover viewport with padding
    private var wallTiles: [SKSpriteNode] = []
    private var wallTexture: SKTexture? = nil
    private var wallAspect: CGFloat = 0.0  // texWidth/texHeight

    // Overlay sizing contract
    // Overlays created from the 1536x1296 master with 432px top and bottom padding will be 432px tall.

    override func didMove(to view: SKView) {
        backgroundColor = .black

        // Section 3.0: Wall base layer (tiled Wall_1)
        wallNode.zPosition = -200
        addChild(wallNode)

        // Create reusable wall tiles (infinite recycler)
        wallTiles = (0..<wallTileCount).map { i in
            let s = SKSpriteNode(color: .clear, size: .zero)
            s.anchorPoint = CGPoint(x: 0.0, y: 0.5) // position.x = left edge
            s.name = "wallTile_\(i)"
            s.zPosition = -200
            wallNode.addChild(s)
            return s
        }

        // Rooms render behind everything else.
        roomsNode.zPosition = -100
        addChild(roomsNode)

        // Create 3 reusable room tiles (prev, current, next).
        roomTiles = (0..<roomTileCount).map { i in
            let container = SKNode()
            container.name = "roomTileContainer_\(i)"
            container.zPosition = -100
            roomsNode.addChild(container)

            // Section 3.2.1: Room background sprite (single image per room; no paneling)
            // Texture name: Room_<RoomId>
            let background = SKSpriteNode(color: .clear, size: .zero)
            background.anchorPoint = CGPoint(x: 0.0, y: 0.0) // left edge, bottom-aligned
            background.name = "roomTile_\(i)_background"
            background.zPosition = -100
            container.addChild(background)

            return RoomTile(container: container, background: background, appliedRoomId: "")
        }

        // Enable SpriteKit touch handling for tap-to-idle.
        isUserInteractionEnabled = true

        // Default sprite setup; textures are applied during first render.
        playerSprite.size = CGSize(width: 128, height: 128)
        playerSprite.position = CGPoint(x: 0, y: (size.height * playerGroundOffsetRatio) + (playerSprite.size.height / 2))
        playerSprite.name = "player"
        playerSprite.zPosition = 0
        addChild(playerSprite)
    }

    // Section 3.3: Touch handling (tap on player -> InputEvent.tapPlayer)
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        let location = touch.location(in: self)
        let hitNodes = nodes(at: location)

        // Emit tap only if the player sprite was tapped.
        let tappedPlayer = hitNodes.contains { node in
            if node === playerSprite { return true }
            return node.name == "player"
        }

        guard tappedPlayer else { return }

        if DebugLog.isEnabled {
            DebugLog.log("InputEvent.tapPlayer emitted (player tapped)")
        }

        onInputEvent?(.tapPlayer)
    }

    // Section 4: Render from snapshot
    func render(state: GameState) {
        // 4.0) Base wall tiling is disabled in the single-background pipeline.
        //      Each room is now a full 1536x1024 (3:2) background image: Room_<RoomId>.

        // 4.1) Render rooms from snapshot (prev/current/next)
        renderRooms(state: state)

        // 4.1) Update visuals if player selection changed
        if state.activePlayerId != currentPlayerId {
            applyVisuals(for: state.activePlayerId, anim: state.playerAnim)
        }

        // 4.2) Apply facing (flip xScale)
        let absScale = max(abs(playerSprite.xScale), 1.0)
        switch state.playerFacing {
        case .right:
            playerSprite.xScale = absScale
        case .left:
            playerSprite.xScale = -absScale
        }

        // 4.3) Apply animation state changes
        applyAnimationIfNeeded(anim: state.playerAnim)

        // 4.4) Camera-relative positioning
        let screenX = state.playerX - state.cameraX
        let groundY = size.height * playerGroundOffsetRatio
        let playerY = groundY + (playerSprite.size.height / 2)
        playerSprite.position = CGPoint(x: screenX, y: playerY)
    }

    // Section 4.5: Rooms (snapshot-only consumption)

    // Section 4.4.1: Base wall tiling (snapshot-only consumption)
    private func renderWall(state: GameState) {
        // Ensure Wall_1 texture is loaded once.
        if wallTexture == nil {
            if hasImageAsset(named: "Wall_1") {
                let tex = SKTexture(imageNamed: "Wall_1")
                wallTexture = tex
                let ts = tex.size()
                wallAspect = (ts.height > 0) ? (ts.width / ts.height) : 0.0

                if DebugLog.isEnabled {
                    DebugLog.log("Loaded Wall_1 texture. texSize=\(Int(ts.width))x\(Int(ts.height)) aspect=\(String(format: "%.4f", wallAspect))")
                }
            } else {
                wallTexture = nil
                wallAspect = 0.0

                if DebugLog.isEnabled {
                    DebugLog.log("Missing wall asset: Wall_1 (base wall will not render)")
                }
            }
        }

        guard let wallTexture, wallAspect > 0.0 else {
            for t in wallTiles {
                t.texture = nil
                t.size = .zero
            }
            return
        }

        // Fit-height sizing: wall tile height matches scene height.
        let h = size.height
        let tileWidth = h * wallAspect
        guard tileWidth > 1 else { return }

        // Anchor tiling to world X=0 for stable seams.
        let camX = state.cameraX
        let leftWorldX = camX
        let startWorldX = floor(leftWorldX / Double(tileWidth)) * Double(tileWidth) - Double(tileWidth)

        // Render a fixed pool.
        var worldX = startWorldX
        for i in 0..<wallTiles.count {
            let tile = wallTiles[i]
            tile.texture = wallTexture
            tile.color = .clear
            tile.size = CGSize(width: tileWidth, height: h)

            let screenX = worldX - camX
            tile.position = CGPoint(x: screenX, y: h / 2.0)

            worldX += Double(tileWidth)
        }
    }

    private func renderRooms(state: GameState) {
        let ids = state.roomIds
        let widths = state.roomWidths

        guard ids.count >= 1, ids.count == widths.count, roomTiles.count == roomTileCount else {
            return
        }

        let count = ids.count
        let currentIndex = max(0, min(state.currentRoomIndex, count - 1))

        let currentRoomId = ids[currentIndex]
        let currentWidth = widths[currentIndex]

        let prevIndex = (currentIndex - 1 + count) % count
        let nextIndex = (currentIndex + 1) % count

        let prevRoomId = ids[prevIndex]
        let nextRoomId = ids[nextIndex]

        let prevWidth = widths[prevIndex]
        let nextWidth = widths[nextIndex]

        // World-space origins for the three tiles
        let currentOriginX = state.currentRoomOriginX
        let prevOriginX = currentOriginX - prevWidth
        let nextOriginX = currentOriginX + currentWidth

        // Convert world-space to screen-space (camera-relative)
        let prevScreenX = prevOriginX - state.cameraX
        let currentScreenX = currentOriginX - state.cameraX
        let nextScreenX = nextOriginX - state.cameraX

        // Height is full scene height; each room tile is a single image fit-to-height.
        let h = size.height

        // Tile 0 = prev, Tile 1 = current, Tile 2 = next
        layoutRoomTile(tileIndex: 0, roomId: prevRoomId, screenOriginX: prevScreenX, roomWidth: prevWidth, height: h)
        layoutRoomTile(tileIndex: 1, roomId: currentRoomId, screenOriginX: currentScreenX, roomWidth: currentWidth, height: h)
        layoutRoomTile(tileIndex: 2, roomId: nextRoomId, screenOriginX: nextScreenX, roomWidth: nextWidth, height: h)
    }

    // Section 4.6: Room tile layout + texture application
    // Section 4.6: Room tile layout + texture application (single background image)
    private func layoutRoomTile(tileIndex: Int, roomId: String, screenOriginX: Double, roomWidth: Double, height: Double) {
        guard tileIndex >= 0, tileIndex < roomTiles.count else { return }

        // Move the container so x=0 within the container corresponds to the room's left edge.
        roomTiles[tileIndex].container.position = CGPoint(x: screenOriginX, y: 0.0)

        let normalizedId = normalizeRoomIdForAsset(roomId)
        let assetName = "Room_\(normalizedId)"

        // Only (re)bind texture when the room changes for this tile.
        if roomTiles[tileIndex].appliedRoomId != roomId {
            roomTiles[tileIndex].appliedRoomId = roomId

            let tex = loadRoomBackgroundTexture(assetName: assetName)
            roomTiles[tileIndex].background.texture = tex
            roomTiles[tileIndex].background.color = .clear
            roomTiles[tileIndex].background.alpha = (tex == nil) ? 0.0 : 1.0
        }

        // Fit-to-height sizing, preserving the background's aspect ratio.
        let h = CGFloat(height)
        let aspect = roomBackgroundAspectRatioCache[assetName] ?? 1.5 // 1536/1024 default (3:2)
        let w = h * aspect

        let bg = roomTiles[tileIndex].background
        bg.size = CGSize(width: w, height: h)
        bg.anchorPoint = CGPoint(x: 0.0, y: 0.0) // bottom-left
        bg.position = CGPoint(x: 0.0, y: 0.0)

        // Diagnostics: warn if GameState's logical roomWidth differs materially from rendered width.
        if DebugLog.isEnabled {
            let diff = abs(Double(w) - roomWidth)
            if diff > 2.0 {
                DebugLog.log("Room width mismatch for \(roomId): rendered=\(Double(w)) vs GameState=\(roomWidth) (diff=\(diff)).")
            }
        }
    }


    // Section 4.6.1: Room background (single image per room)
    // Asset convention:
    //   Room_<RoomId>_Overlay
    // Example:
    //   Room_Entryway_Overlay
    // Section 4.7: Room texture loading (single background)
    private func loadRoomBackgroundTexture(assetName: String) -> SKTexture? {
        if let cached = roomBackgroundTextureCache[assetName] {
            return cached
        }

        if hasImageAsset(named: assetName) {
            let tex = SKTexture(imageNamed: assetName)
            tex.filteringMode = .nearest
            roomBackgroundTextureCache[assetName] = tex

            let ts = tex.size()
            let aspect = (ts.height > 0) ? (ts.width / ts.height) : 1.5
            roomBackgroundAspectRatioCache[assetName] = aspect

            if DebugLog.isEnabled {
                DebugLog.log("Loaded room background asset: \(assetName) texSize=\(Int(ts.width))x\(Int(ts.height)) aspect=\(String(format: "%.4f", aspect))")
            }
            return tex
        } else {
            roomBackgroundTextureCache[assetName] = nil
            roomBackgroundAspectRatioCache[assetName] = 1.5
            if DebugLog.isEnabled {
                DebugLog.log("Missing room background asset: \(assetName)")
            }
            return nil
        }
    }

    // Section 4.8: Room texture naming
    // Asset convention:
    //   Room_<RoomId>
    // Examples:
    //   Room_Entryway, Room_Hallway_1, Room_JackAndJill, Room_Livingroom
    private func normalizeRoomIdForAsset(_ roomId: String) -> String {
        // With the new pipeline, GameState.roomIds are expected to already match asset suffixes.
        // Keep this hook for any future normalization/mapping needs.
        return roomId
    }

    // Section 4.9: Asset existence check
    private func hasImageAsset(named: String) -> Bool {
        return UIImage(named: named) != nil
    }

    // Section 5: Visuals + animation
    private func applyVisuals(for playerId: String, anim: PlayerAnim) {
        currentPlayerId = playerId

        let visuals = loadVisuals(for: playerId)
        playerSprite.texture = visuals.idle

        // Reset actions to avoid cross-player action leakage
        playerSprite.removeAllActions()
        if anim == .run {
            playerSprite.run(visuals.runAction, withKey: "run")
        }
    }

    private func applyAnimationIfNeeded(anim: PlayerAnim) {
        let visuals = loadVisuals(for: currentPlayerId.isEmpty ? "Finley" : currentPlayerId)

        switch anim {
        case .idle:
            // Stop run loop if present; ensure idle texture is set.
            playerSprite.removeAction(forKey: "run")
            playerSprite.texture = visuals.idle
        case .run:
            // Start run loop if not already running.
            if playerSprite.action(forKey: "run") == nil {
                playerSprite.run(visuals.runAction, withKey: "run")
            }
        }
    }

    // Section 6: Texture loading (safe fallback)
    private func loadVisuals(for playerId: String) -> PlayerVisuals {
        if let cached = visualsCache[playerId] { return cached }

        // If assets for the requested player are missing, fall back to Finley.
        let resolvedId = hasIdleAsset(for: playerId) ? playerId : "Finley"

        let idleName = "\(resolvedId)_idle"

        // Keep uniform run-frame count across all players.
        // NOTE: This range should match your current agreed frame count.
        let runNames = (1...8).map { "\(resolvedId)_run_\($0)" }

        let idleTexture = SKTexture(imageNamed: idleName)
        let runTextures = runNames.map { SKTexture(imageNamed: $0) }

        let runAction = SKAction.repeatForever(
            SKAction.animate(with: runTextures, timePerFrame: 0.08, resize: false, restore: false)
        )

        let visuals = PlayerVisuals(idle: idleTexture, runFrames: runTextures, runAction: runAction)
        visualsCache[playerId] = visuals
        return visuals
    }

    private func hasIdleAsset(for playerId: String) -> Bool {
        // Use UIKit to detect presence; SKTexture(imageNamed:) does not reliably indicate missing assets.
        return UIImage(named: "\(playerId)_idle") != nil
    }
}

// End of GameScene.swift

// GameScene.swift
// End of File: GameScene.swift

