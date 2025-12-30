// GameHostView.swift
// UI
// SpriteKit host view for Running from Puppies.
// Owns the runtime (FixedStepDriver) and wires input to GameCore deterministically.
// Rendering consumes GameState snapshots only.
//
// Section 1: Imports

import SwiftUI
import SpriteKit

struct GameHostView: View {
    // Section 2: Dependencies
    let engine: GameCoreEngine
    let activePlayerId: String

    // Section 3: Runtime + renderer
    private let driver: FixedStepDriver
    private let scene = GameScene()

    @StateObject private var input = SwipeInputCollector()

    init(engine: GameCoreEngine, activePlayerId: String) {
        self.engine = engine
        self.activePlayerId = activePlayerId
        self.driver = FixedStepDriver(engine: engine)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SpriteView(scene: scene)
                    .ignoresSafeArea()
                    .gesture(
                        DragGesture(minimumDistance: input.minimumDistance, coordinateSpace: .local)
                            .onEnded { value in
                                input.handleDrag(translation: value.translation)
                            }
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 1.0)
                            .onEnded { _ in
                                // Flush debug log to Documents (Files app visibility is out of scope).
                                guard DebugLog.isEnabled else { return }
                                _ = DebugLog.flushToFile()
                            }
                    )
            }
            .onAppear {
                // Section 4: Configure renderer sizing/scaling
                scene.size = proxy.size
                scene.scaleMode = .resizeFill

                // Section 5: Apply UI-owned snapshot fields
                engine.setViewWidth(Double(proxy.size.width))
                engine.setViewHeight(Double(proxy.size.height))
                engine.setActivePlayerId(activePlayerId)

                // Section 6: Wire callbacks
                driver.onStateUpdated = { state in
                    scene.render(state: state)
                }
                driver.drainInputEvents = { input.drain() }

                // Route SpriteKit tap events into the same deterministic input queue.
                scene.onInputEvent = { event in
                    input.enqueue(event)
                }

                // Section 7: Start runtime
                driver.start()
            }
            .onChange(of: proxy.size) { newSize in
                engine.setViewWidth(Double(newSize.width))
                engine.setViewHeight(Double(newSize.height))
                scene.size = newSize
            }
            .onDisappear {
                driver.stop()
            }
        }
    }
}

// End of GameHostView.swift
