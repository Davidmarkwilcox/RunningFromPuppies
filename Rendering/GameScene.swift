// GameScene.swift
// Rendering
// SpriteKit renderer consuming GameState snapshots.
// Rendering must never mutate GameCore state.
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

    private var visualsCache: [String: PlayerVisuals] = [:]
    private var currentPlayerId: String = ""

    // Section 3: Nodes
    private let playerSprite = SKSpriteNode()

    override func didMove(to view: SKView) {
        backgroundColor = .black

        // Default sprite setup; textures are applied during first render.
        playerSprite.size = CGSize(width: 128, height: 128)
        playerSprite.position = CGPoint(x: 0, y: size.height / 2)
        addChild(playerSprite)
    }

    // Section 4: Render from snapshot
    func render(state: GameState) {
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
        playerSprite.position = CGPoint(x: screenX, y: size.height / 2)
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
        let runNames = (1...8).map { "\(resolvedId)_run_\($0)" }

        let idleTexture = SKTexture(imageNamed: idleName)
        let runTextures = runNames.map { SKTexture(imageNamed: $0) }

        let runAction = SKAction.repeatForever(SKAction.animate(with: runTextures, timePerFrame: 0.10, resize: false, restore: false))

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
