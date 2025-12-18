// GameScene.swift
// Rendering
// SpriteKit renderer consuming GameState snapshots.

import SpriteKit

final class GameScene: SKScene {
    private let playerNode = SKShapeNode(rectOf: CGSize(width: 50, height: 50))

    override func didMove(to view: SKView) {
        backgroundColor = .black
        playerNode.fillColor = .white
        addChild(playerNode)
    }

    func render(state: GameState) {
        playerNode.position = CGPoint(x: state.playerX, y: size.height / 2)
    }
}

// End of GameScene.swift
