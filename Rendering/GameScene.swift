// File: GameScene.swift
// GameScene_20260102-1720.swift
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
    private let playerGroundOffsetRatio: CGFloat = 0.00

    // Section 3.1: Input event sink (Rendering -> Input).
    // GameScene must never mutate GameCore state; it only emits InputEvents.
    var onInputEvent: ((InputEvent) -> Void)?

    // Section 2.9: HUD (Timer + Pause)
    private let hudNode = SKNode()
    private let scoreLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let timerLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let pauseLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let pauseHitTarget = SKShapeNode(rectOf: CGSize(width: 56, height: 40), cornerRadius: 8)
    

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

        // Section 2.9.1: HUD setup
        setupHUD()

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

    // Section 2.9.2: Configure HUD nodes
    private func setupHUD() {
        hudNode.zPosition = 10_000
        hudNode.name = "hudNode"
        addChild(hudNode)

        scoreLabel.fontSize = 22
        scoreLabel.horizontalAlignmentMode = .right
        scoreLabel.verticalAlignmentMode = .center
        scoreLabel.fontColor = .white
        scoreLabel.text = "Score: 0"
        scoreLabel.name = "hud_scoreLabel"

        timerLabel.fontSize = 22
        timerLabel.horizontalAlignmentMode = .right
        timerLabel.verticalAlignmentMode = .center
        timerLabel.fontColor = .white
        timerLabel.text = "00:00"
        timerLabel.name = "hud_timerLabel"
        hudNode.addChild(scoreLabel)
        hudNode.addChild(timerLabel)

        pauseLabel.fontSize = 22
        pauseLabel.horizontalAlignmentMode = .center
        pauseLabel.verticalAlignmentMode = .center
        pauseLabel.fontColor = .white
        pauseLabel.text = "⏸"
        pauseLabel.name = "hud_pauseLabel"
        hudNode.addChild(pauseLabel)

        // Larger invisible hit target for reliable tapping.
        pauseHitTarget.fillColor = .white
        pauseHitTarget.strokeColor = .white
        pauseHitTarget.alpha = 0.001
        pauseHitTarget.zPosition = -1
        pauseHitTarget.name = "hud_pauseHitTarget"
        hudNode.addChild(pauseHitTarget)

        layoutHUD()
    }

    // Section 2.9.3: Layout HUD (top-right)
    private func layoutHUD() {
        // Coordinate system: (0,0) bottom-left with default anchor; use scene size.
        // NOTE: We deliberately inset from the right edge to avoid the HUD being too close to (or clipped by) the screen edge.
        let topPadding: CGFloat = 18
        let rightInset: CGFloat = 70   // keep HUD comfortably on-screen
        let timerToPauseGap: CGFloat = 26
        let scoreToTimerGap: CGFloat = 36 // breathing room between score and timer

        let topY = size.height - topPadding

        // Pause icon (top-right, inset)
        let pauseX = size.width - rightInset
        pauseLabel.position = CGPoint(x: pauseX, y: topY)

        // Larger invisible hit target centered on the pause icon
        pauseHitTarget.position = pauseLabel.position

        // Timer sits to the left; timer label is right-aligned so it "grows" left as time increases
        let timerRightX = pauseX - timerToPauseGap
        timerLabel.position = CGPoint(x: timerRightX, y: topY)

        // Score sits to the left of the timer.
        // IMPORTANT: compute score's right edge based on the timer's rendered width to prevent overlap.
        let timerWidth = max(10, timerLabel.frame.width)
        let scoreRightX = timerRightX - timerWidth - scoreToTimerGap
        scoreLabel.position = CGPoint(x: max(12, scoreRightX), y: topY)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        layoutHUD()
    }

    // Section 2.9.5: HUD touch handling (pause / resume)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)

        // If the user taps the pause icon (or its hit target), emit a deterministic togglePause InputEvent.
        let hitNodes = nodes(at: location)
        let tappedPause = hitNodes.contains { node in
            node.name == "hud_pauseHitTarget" || node.name == "hud_pauseLabel"
        }

        if tappedPause {
            onInputEvent?(.togglePause)
            return
        }

        // (Reserved) Other touch interactions can be added here later (e.g., tap player to stop).
    }

    // Section 2.9.4: HUD rendering
    private func renderHUD(state: GameState) {
        scoreLabel.text = "Score: \(state.score)"

        timerLabel.text = formatTimeMMSS(state.elapsedLevelTime)
        // When game is running, show pause icon; when paused, show play icon.
        pauseLabel.text = state.isPaused ? "▶︎" : "⏸"
        // Keep layout stable as label widths change (e.g., Score grows)
        layoutHUD()

    }

    private func formatTimeMMSS(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mm = total / 60
        let ss = total % 60
        return String(format: "%02d:%02d", mm, ss)
    }

    func render(state: GameState) {
        // 4.0) Base wall tiling is disabled in the single-background pipeline.
        //      Each room is now a full 1536x1024 (3:2) background image: Room_<RoomId>.

        // 4.1) Render rooms from snapshot (prev/current/next)
        renderRooms(state: state)

        // 4.0.1) HUD overlay
        renderHUD(state: state)

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
        let playerY = groundY + state.playerY + (playerSprite.size.height / 2)
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

        // Fit-to-height sizing:
        // Rendering uses GameCore's roomWidth (source of truth) to avoid drift between
        // logical indexing/origins and what is actually drawn.
        let h = CGFloat(height)
        let bg = roomTiles[tileIndex].background

        // Expected width based on texture aspect (diagnostics only).
        let aspect = roomBackgroundAspectRatioCache[assetName] ?? 1.5 // 1536/1024 default (3:2)
        let expectedW = h * aspect

        // Authoritative rendered width (from GameCore).
        let w = CGFloat(max(roomWidth, 0.0))
        bg.size = CGSize(width: w, height: h)
        bg.anchorPoint = CGPoint(x: 0.0, y: 0.0) // bottom-left
        bg.position = CGPoint(x: 0.0, y: 0.0)

        // Diagnostics: warn if the computed texture aspect differs materially from GameCore's roomWidth.
        if DebugLog.isEnabled {
            let diff = abs(Double(expectedW) - roomWidth)
            if diff > 2.0 {
                DebugLog.log("Room width mismatch for \(roomId): expectedFromAspect=\(Double(expectedW)) vs GameState=\(roomWidth) (diff=\(diff)).")
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
        let runNames = (1...16).map { "\(resolvedId)_run_\($0)" }

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
// End of GameScene_20260102-1720.swift
