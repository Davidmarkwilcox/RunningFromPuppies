// ContentView.swift

import SwiftUI
import SpriteKit

struct ContentView: View {

    // Create the scene once (do not recreate on every body evaluation)
    private let scene: SKScene = {
        let s = GameScene()
        s.scaleMode = .resizeFill
        s.backgroundColor = .black
        return s
    }()

    var body: some View {
        GeometryReader { proxy in
            SpriteView(scene: scene)
                .ignoresSafeArea()
                .onAppear {
                    // Ensure the scene has a non-zero size on first presentation
                    scene.size = proxy.size
                }
                .onChange(of: proxy.size) { newSize in
                    // Keep the scene sized correctly if layout changes
                    scene.size = newSize
                }
        }
    }
}

// ContentView.swift
