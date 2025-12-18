// ContentView.swift
// UI
// Hosts SpriteKit and starts the fixed-step runtime.

import SwiftUI
import SpriteKit

struct ContentView: View {
    private let engine = GameCoreEngine()
    private let driver: FixedStepDriver
    private let scene = GameScene()

    @StateObject private var input = SwipeInputCollector()

    init() {
        let engine = GameCoreEngine()
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

                // Debug-only overlay: long press anywhere to flush logs to a file.
                Color.clear
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 1.0)
                            .onEnded { _ in
                                print("[DEBUG] Flush gesture recognized")   // proof the gesture fired
                                guard DebugLog.isEnabled else {
                                    print("[DEBUG] DebugLog.isEnabled is false; not flushing.")
                                    return
                                }
                                let url = DebugLog.flushToFile()
                                print("[DEBUG] flushToFile() returned: \(String(describing: url))")
                            }
                    )
            }
            .ignoresSafeArea()
            .background(Color.black) // prevents SwiftUI white background showing through
            .onAppear {
                scene.size = proxy.size
                scene.scaleMode = .resizeFill

                driver.onStateUpdated = { state in
                    scene.render(state: state)
                }
                driver.drainInputEvents = { input.drain() }
                driver.start()
            }
            .onDisappear {
                driver.stop()
            }
        }
    }
}

// End of ContentView.swift
