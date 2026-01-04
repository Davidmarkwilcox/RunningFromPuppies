// File: GameScene.swift
// GameScene_20260103-1538.swift
// Purpose: SpriteKit renderer that consumes immutable GameState snapshots and renders the world (rooms + player + puppy + HUD).
//          Rendering must never mutate GameCore state. Input is emitted as InputEvents via callbacks.
//
// Sections:
// 1. Imports
// 2. Visual caches (Player/Puppy)
// 3. Nodes (Rooms, Player, Puppy, HUD)
// 4. Input handling (touch -> InputEvents)
// 5. Render pipeline (rooms, HUD, entities)
// 6. Asset helpers
//
// End-of-file marker is included at the bottom.

// Section 1: Imports
import SpriteKit
import UIKit

final class GameScene: SKScene {

    // -------------------------------------------------------------------------
    // Section 2: Visual cache
    // -------------------------------------------------------------------------
    private struct PlayerVisuals {
        let idle: SKTexture
        let runFrames: [SKTexture]
        let runAction: SKAction

        // Capture animation (Finley_capture_1 ... Finley_capture_9). Played when GameCore marks playerAnim == .captured.
        let captureFrames: [SKTexture]
        let captureAction: SKAction
    }

    private struct PuppyVisuals {
        let idle: SKTexture
        let runFrames: [SKTexture]
        let runAction: SKAction

        // Lick animation (Puppy_<Id>_lick_1 ... Puppy_<Id>_lick_9). Played when GameCore marks puppyAnim == .lick.
        let lickFrames: [SKTexture]
        let lickAction: SKAction
    }

    // -------------------------------------------------------------------------
    // Section 2.1: Room tile model (single background per room; no paneling)
    // -------------------------------------------------------------------------
    private struct RoomTile {
        let container: SKNode
        let background: SKSpriteNode   // Full-room background: Room_<RoomId>
        var appliedRoomId: String      // For change detection
    }

    // Room background caches
    private var roomBackgroundTextureCache: [String: SKTexture?] = [:]
    private var roomBackgroundAspectRatioCache: [String: CGFloat] = [:]  // texWidth/texHeight

    // Player visual caches
    private var playerVisualsCache: [String: PlayerVisuals] = [:]
    private var currentPlayerId: String = ""

    // Puppy visual caches
    private var puppyVisualsCache: [String: PuppyVisuals] = [:]
    private var currentPuppyId: String = ""

    // -------------------------------------------------------------------------
    // Section 3: Nodes
    // -------------------------------------------------------------------------
    private let playerSprite = SKSpriteNode()
    private let puppySprite = SKSpriteNode()


    // Section 3.0.1: Puppy visual scale (tunable). Requested: 1/3 size.
    private let puppyScale: CGFloat = 1.0 / 2.0

    // Player vertical placement (0 = bottom of screen). Keep consistent across entities.
    private let groundOffsetRatio: CGFloat = 0.00

    // Section 3.1: Input event sink (Rendering -> Input). Rendering must not mutate GameCore.
    var onInputEvent: ((InputEvent) -> Void)?

    // Section 3.1.1: UI callback for restarting after capture (Rendering -> Runtime).
    // GameScene does not mutate GameCore; the host (GameHostView) can reset the engine/scene when invoked.
    var onPlayAgain: (() -> Void)?

    // Section 3.2: HUD (Timer + Score + Pause)
    private let hudNode = SKNode()
    private let scoreLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let timerLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let pauseLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let pauseHitTarget = SKShapeNode(rectOf: CGSize(width: 56, height: 40), cornerRadius: 8)

    // Section 3.2.1: "Play Again" overlay (shown after capture)
    private let playAgainNode = SKNode()
    private let playAgainLabel = SKLabelNode(fontNamed: "Menlo-Bold")
    private let playAgainHitTarget = SKShapeNode(rectOf: CGSize(width: 180, height: 52), cornerRadius: 10)

    // Section 3.3: Rooms (3-room recycler; each room is a single 1536x1024 background image: Room_<RoomId>)
    private let roomsNode = SKNode()
    private let roomTileCount = 3
    private var roomTiles: [RoomTile] = []

    // -------------------------------------------------------------------------
    // Section 3.4: didMove (scene setup)
    // -------------------------------------------------------------------------
    override func didMove(to view: SKView) {
        backgroundColor = .black

        // HUD setup
        setupHUD()

        // Rooms render behind everything else.
        roomsNode.zPosition = -100
        addChild(roomsNode)

        // Create 3 reusable room tiles (prev, current, next).
        roomTiles = (0..<roomTileCount).map { i in
            let container = SKNode()
            container.name = "roomTileContainer_\(i)"
            container.zPosition = -100
            roomsNode.addChild(container)

            let background = SKSpriteNode(color: .clear, size: .zero)
            background.anchorPoint = CGPoint(x: 0.0, y: 0.0) // left edge, bottom-aligned
            background.name = "roomTile_\(i)_background"
            background.zPosition = -100
            container.addChild(background)

            return RoomTile(container: container, background: background, appliedRoomId: "")
        }

        // Enable SpriteKit touch handling for pause + player tap stop.
        isUserInteractionEnabled = true

        // Player sprite defaults; textures applied during first render.
        playerSprite.size = CGSize(width: 128, height: 128)
        playerSprite.position = CGPoint(x: 0, y: (size.height * groundOffsetRatio) + (playerSprite.size.height / 2))
        playerSprite.name = "player"
        playerSprite.zPosition = 0
        addChild(playerSprite)

        // Puppy sprite defaults; textures applied during first render.
        puppySprite.size = CGSize(width: 128, height: 128)
        puppySprite.setScale(puppyScale)
        puppySprite.position = CGPoint(x: -200, y: (size.height * groundOffsetRatio) + (puppySprite.frame.height / 2))
        puppySprite.name = "puppy"
        puppySprite.zPosition = 0
        addChild(puppySprite)
    }

    // -------------------------------------------------------------------------
    // Section 4: Touch handling
    // -------------------------------------------------------------------------

    // 4.1: Tap on player -> InputEvent.tapPlayer (hard stop)
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }

        let location = touch.location(in: self)
        let hitNodes = nodes(at: location)
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

    // 4.2: Pause toggle (tap hit target)
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let location = touch.location(in: self)

        let hitNodes = nodes(at: location)
        let tappedPause = hitNodes.contains { node in
            node.name == "hud_pauseHitTarget" || node.name == "hud_pauseLabel"
        }

        if tappedPause {
            onInputEvent?(.togglePause)
            return
        }
    }

    // -------------------------------------------------------------------------
    // Section 5: HUD
    // -------------------------------------------------------------------------
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
        layoutPlayAgainOverlay()
    }


    // -------------------------------------------------------------------------
    // Section 5.1: Play Again overlay (shown after capture)
    // -------------------------------------------------------------------------
    private func setupPlayAgainOverlay() {
        playAgainNode.zPosition = 10_010
        playAgainNode.name = "playAgainNode"
        addChild(playAgainNode)

        // Label
        playAgainLabel.fontSize = 26
        playAgainLabel.horizontalAlignmentMode = .center
        playAgainLabel.verticalAlignmentMode = .center
        playAgainLabel.fontColor = .white
        playAgainLabel.text = "Play Again"
        playAgainLabel.name = "ui_playAgainLabel"
        playAgainNode.addChild(playAgainLabel)

        // Hit target (invisible but tappable)
        playAgainHitTarget.fillColor = .clear
        playAgainHitTarget.strokeColor = .clear
        playAgainHitTarget.alpha = 1.0
        playAgainHitTarget.zPosition = -1
        playAgainHitTarget.name = "ui_playAgainHitTarget"
        playAgainNode.addChild(playAgainHitTarget)

        // Kept disabled; Play Again is hosted in SwiftUI.
        playAgainNode.isHidden = true

        layoutPlayAgainOverlay()
    }

    private func layoutPlayAgainOverlay() {
        // Centered horizontally; placed ~25% down from top.
        let centerX = size.width / 2.0
        let y = size.height * 0.62
        playAgainLabel.position = CGPoint(x: centerX, y: y)
        playAgainHitTarget.position = playAgainLabel.position
    }

    private func layoutHUD() {
        let topPadding: CGFloat = 18
        let rightInset: CGFloat = 70
        let timerToPauseGap: CGFloat = 26
        let scoreToTimerGap: CGFloat = 36

        let topY = size.height - topPadding

        let pauseX = size.width - rightInset
        pauseLabel.position = CGPoint(x: pauseX, y: topY)

        pauseHitTarget.position = pauseLabel.position

        let timerRightX = pauseX - timerToPauseGap
        timerLabel.position = CGPoint(x: timerRightX, y: topY)

        let timerWidth = max(10, timerLabel.frame.width)
        let scoreRightX = timerRightX - timerWidth - scoreToTimerGap
        scoreLabel.position = CGPoint(x: max(12, scoreRightX), y: topY)
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        layoutHUD()
        layoutPlayAgainOverlay()
    }

    private func renderHUD(state: GameState) {
        scoreLabel.text = "Score: \(state.score)"
        timerLabel.text = formatTimeMMSS(state.elapsedLevelTime)
        pauseLabel.text = state.isPaused ? "▶︎" : "⏸"
        layoutHUD()
        // Play Again is hosted in SwiftUI (GameHostView). Keep SpriteKit overlay disabled.
        playAgainNode.isHidden = true
}

    private func formatTimeMMSS(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let mm = total / 60
        let ss = total % 60
        return String(format: "%02d:%02d", mm, ss)
    }

    // -------------------------------------------------------------------------
    // Section 6: Main render entry point
    // -------------------------------------------------------------------------
    func render(state: GameState) {
        // 6.1 Rooms (prev/current/next)
        renderRooms(state: state)

        // 6.2 HUD overlay
        renderHUD(state: state)

        // 6.3 Player visuals (if selection changed)
        if state.activePlayerId != currentPlayerId {
            applyPlayerVisuals(for: state.activePlayerId, anim: state.playerAnim)
        }

        // 6.4 Puppy visuals (if selection changed)
        if state.activePuppyId != currentPuppyId {
            applyPuppyVisuals(for: state.activePuppyId, anim: state.puppyAnim)
        }

        // 6.5 Apply facing (flip xScale)
        applyFacing(sprite: playerSprite, facing: state.playerFacing)
        applyFacing(sprite: puppySprite, facing: state.puppyFacing)

        // 6.6 Apply animation state changes (player + puppy)
        applyPlayerAnimationIfNeeded(anim: state.playerAnim)
        applyPuppyAnimationIfNeeded(anim: state.puppyAnim)

        // 6.7 Camera-relative positioning (world -> screen)
        let groundY = size.height * groundOffsetRatio

        // Player
        let playerScreenX = state.playerX - state.cameraX
        let playerY = groundY + state.playerY + (playerSprite.size.height / 2)
        playerSprite.position = CGPoint(x: playerScreenX, y: playerY)

        // Puppy
        let puppyScreenX = state.puppyX - state.cameraX
        let puppyY = groundY + state.puppyY + (puppySprite.frame.height / 2)
        puppySprite.position = CGPoint(x: puppyScreenX, y: puppyY)
    }

    private func applyFacing(sprite: SKSpriteNode, facing: PlayerFacing) {
        let absScale = max(abs(sprite.xScale), 0.0001)
        switch facing {
        case .right:
            sprite.xScale = absScale
        case .left:
            sprite.xScale = -absScale
        }
    }

    // -------------------------------------------------------------------------
    // Section 6.1: Rooms rendering (snapshot-only consumption)
    // -------------------------------------------------------------------------
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

        let currentOriginX = state.currentRoomOriginX
        let prevOriginX = currentOriginX - prevWidth
        let nextOriginX = currentOriginX + currentWidth

        let prevScreenX = prevOriginX - state.cameraX
        let currentScreenX = currentOriginX - state.cameraX
        let nextScreenX = nextOriginX - state.cameraX

        let h = size.height

        layoutRoomTile(tileIndex: 0, roomId: prevRoomId, screenOriginX: prevScreenX, roomWidth: prevWidth, height: h)
        layoutRoomTile(tileIndex: 1, roomId: currentRoomId, screenOriginX: currentScreenX, roomWidth: currentWidth, height: h)
        layoutRoomTile(tileIndex: 2, roomId: nextRoomId, screenOriginX: nextScreenX, roomWidth: nextWidth, height: h)
    }

    private func layoutRoomTile(tileIndex: Int, roomId: String, screenOriginX: Double, roomWidth: Double, height: Double) {
        guard tileIndex >= 0, tileIndex < roomTiles.count else { return }

        roomTiles[tileIndex].container.position = CGPoint(x: screenOriginX, y: 0.0)

        let normalizedId = normalizeRoomIdForAsset(roomId)
        let assetName = "Room_\(normalizedId)"

        if roomTiles[tileIndex].appliedRoomId != roomId {
            roomTiles[tileIndex].appliedRoomId = roomId

            let tex = loadRoomBackgroundTexture(assetName: assetName)
            roomTiles[tileIndex].background.texture = tex
            roomTiles[tileIndex].background.color = .clear
            roomTiles[tileIndex].background.alpha = (tex == nil) ? 0.0 : 1.0
        }

        let h = CGFloat(height)
        let bg = roomTiles[tileIndex].background

        let aspect = roomBackgroundAspectRatioCache[assetName] ?? 1.5
        let expectedW = h * aspect

        let w = CGFloat(max(roomWidth, 0.0))
        bg.size = CGSize(width: w, height: h)
        bg.anchorPoint = CGPoint(x: 0.0, y: 0.0)
        bg.position = CGPoint(x: 0.0, y: 0.0)

        if DebugLog.isEnabled {
            let diff = abs(Double(expectedW) - roomWidth)
            if diff > 2.0 {
                DebugLog.log("Room width mismatch for \(roomId): expectedFromAspect=\(Double(expectedW)) vs GameState=\(roomWidth) (diff=\(diff)).")
            }
        }
    }

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

    private func normalizeRoomIdForAsset(_ roomId: String) -> String {
        return roomId
    }

    private func hasImageAsset(named: String) -> Bool {
        return UIImage(named: named) != nil
    }

    // -------------------------------------------------------------------------
    // Section 7: Player visuals + animation
    // -------------------------------------------------------------------------
    private func applyPlayerVisuals(for playerId: String, anim: PlayerAnim) {
        currentPlayerId = playerId

        let visuals = loadPlayerVisuals(for: playerId)
        playerSprite.texture = visuals.idle

        playerSprite.removeAllActions()
        if anim == .run {
            playerSprite.run(visuals.runAction, withKey: "run")
        } else if anim == .captured {
            playerSprite.texture = visuals.captureFrames.first ?? visuals.idle
            playerSprite.run(visuals.captureAction, withKey: "capture")
        }
    }

    private func applyPlayerAnimationIfNeeded(anim: PlayerAnim) {
        let visuals = loadPlayerVisuals(for: currentPlayerId.isEmpty ? "Finley" : currentPlayerId)

        switch anim {
        case .idle:
            playerSprite.removeAction(forKey: "run")
            playerSprite.texture = visuals.idle

        case .run:
            if playerSprite.action(forKey: "run") == nil {
                playerSprite.run(visuals.runAction, withKey: "run")
            }

        case .captured:
            playerSprite.removeAction(forKey: "run")
            // Play capture animation (9 frames) if not already running.
            if playerSprite.action(forKey: "capture") == nil {
                playerSprite.texture = visuals.captureFrames.first ?? visuals.idle
                playerSprite.run(visuals.captureAction, withKey: "capture")
            }
        }
    }

    private func loadPlayerVisuals(for playerId: String) -> PlayerVisuals {
        if let cached = playerVisualsCache[playerId] { return cached }

        let resolvedId = hasImageAsset(named: "\(playerId)_idle") ? playerId : "Finley"

        let idleName = "\(resolvedId)_idle"
        let runNames = (1...16).map { "\(resolvedId)_run_\($0)" }
        let captureNames = (1...9).map { "\(resolvedId)_capture_\($0)" }

        let idleTexture = SKTexture(imageNamed: idleName)
        let runTextures = runNames.map { SKTexture(imageNamed: $0) }

        // Capture frames fallback: if not present, use idle as a single-frame animation.
        let hasFirstCapture = hasImageAsset(named: captureNames.first ?? "")
        let captureTextures: [SKTexture] = hasFirstCapture ? captureNames.map { SKTexture(imageNamed: $0) } : [idleTexture]

        let runAction = SKAction.repeatForever(
            SKAction.animate(with: runTextures, timePerFrame: 0.08, resize: false, restore: false)
        )

        // Play once then hold.
        let captureAction = SKAction.sequence([
            SKAction.animate(with: captureTextures, timePerFrame: 0.08, resize: false, restore: false),
            SKAction.wait(forDuration: 9999)
        ])

        let visuals = PlayerVisuals(
            idle: idleTexture,
            runFrames: runTextures,
            runAction: runAction,
            captureFrames: captureTextures,
            captureAction: captureAction
        )
        playerVisualsCache[playerId] = visuals
        return visuals
    }

    // -------------------------------------------------------------------------
    // Section 8: Puppy visuals + animation
    // Asset convention (recommended):
    //   Puppy_<PuppyId>_idle
    //   Puppy_<PuppyId>_run_1 ... Puppy_<PuppyId>_run_16
    //   Puppy_<PuppyId>_lick_1 ... Puppy_<PuppyId>_lick_9
    // If assets are missing, a visible placeholder is used.
    // -------------------------------------------------------------------------
    private func applyPuppyVisuals(for puppyId: String, anim: PuppyAnim) {
        currentPuppyId = puppyId

        let visuals = loadPuppyVisuals(for: puppyId)
        puppySprite.texture = visuals.idle

        puppySprite.removeAllActions()
        if anim == .run {
            puppySprite.run(visuals.runAction, withKey: "puppy_run")
        } else if anim == .lick {
            puppySprite.run(visuals.lickAction, withKey: "puppy_lick")
        }
    }

    private func applyPuppyAnimationIfNeeded(anim: PuppyAnim) {
        let visuals = loadPuppyVisuals(for: currentPuppyId.isEmpty ? "Lilly" : currentPuppyId)

        switch anim {
        case .idle:
            puppySprite.removeAction(forKey: "puppy_run")
            puppySprite.removeAction(forKey: "puppy_lick")
            puppySprite.texture = visuals.idle

        case .run:
            puppySprite.removeAction(forKey: "puppy_lick")
            if puppySprite.action(forKey: "puppy_run") == nil {
                puppySprite.run(visuals.runAction, withKey: "puppy_run")
            }

        case .lick:
            puppySprite.removeAction(forKey: "puppy_run")
            if puppySprite.action(forKey: "puppy_lick") == nil {
                puppySprite.run(visuals.lickAction, withKey: "puppy_lick")
            }
        }
    }

    private func loadPuppyVisuals(for puppyId: String) -> PuppyVisuals {
        if let cached = puppyVisualsCache[puppyId] { return cached }

        let base = "Puppy_\(puppyId)"
        let idleName = "\(base)_idle"
        let runNames = (1...16).map { "\(base)_run_\($0)" }
        let lickNames = (1...9).map { "\(base)_lick_\($0)" }

        let hasIdle = hasImageAsset(named: idleName)

        // If puppy art is missing, build a visible placeholder to avoid silent failures.
        if !hasIdle {
            if DebugLog.isEnabled {
                DebugLog.log("Missing puppy idle asset: \(idleName) (using placeholder textures)")
            }

            // Placeholder textures: use colored squares generated from SKTexture via sprite color.
            // We'll still use SKTexture(imageNamed:) to keep the pipeline simple; the sprite will fall back to color.
            let placeholderIdle = SKTexture(imageNamed: idleName)
            let placeholderRun = runNames.map { SKTexture(imageNamed: $0) }
            let placeholderLick = lickNames.map { SKTexture(imageNamed: $0) }

            let runAction = SKAction.repeatForever(
                SKAction.animate(with: placeholderRun, timePerFrame: 0.08, resize: false, restore: false)
            )
            let lickAction = SKAction.sequence([
            SKAction.animate(with: placeholderLick, timePerFrame: 0.08, resize: false, restore: false),
            SKAction.wait(forDuration: 9999)
        ])

            // Make the sprite visible even if the textures are empty.
            puppySprite.color = .white
            puppySprite.colorBlendFactor = 1.0

            let visuals = PuppyVisuals(
                idle: placeholderIdle,
                runFrames: placeholderRun,
                runAction: runAction,
                lickFrames: placeholderLick,
                lickAction: lickAction
            )
            puppyVisualsCache[puppyId] = visuals
            return visuals
        }

        // Normal path: real assets present
        puppySprite.colorBlendFactor = 0.0

        let idleTexture = SKTexture(imageNamed: idleName)
        let runTextures = runNames.map { SKTexture(imageNamed: $0) }
        let lickTextures = lickNames.map { SKTexture(imageNamed: $0) }

        let runAction = SKAction.repeatForever(
            SKAction.animate(with: runTextures, timePerFrame: 0.08, resize: false, restore: false)
        )

        let lickAction = SKAction.sequence([
            SKAction.animate(with: lickTextures, timePerFrame: 0.08, resize: false, restore: false),
            SKAction.wait(forDuration: 9999)
        ])

        let visuals = PuppyVisuals(idle: idleTexture, runFrames: runTextures, runAction: runAction, lickFrames: lickTextures, lickAction: lickAction)
        puppyVisualsCache[puppyId] = visuals
        return visuals
    }
}

// End of GameScene.swift
