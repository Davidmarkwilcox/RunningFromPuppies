// File: GameHostView.swift
// UI
// SpriteKit host view for Running from Puppies.
// Owns the runtime (FixedStepDriver) and wires input to GameCore deterministically.
// Rendering consumes GameState snapshots only.
//
// This file owns the "Play Again" restart loop for a run. On restart, it:
// - Stops the current FixedStepDriver
// - Clears any queued input events
// - Creates a fresh GameCoreEngine + GameScene + FixedStepDriver
// - Re-wires callbacks deterministically
//
// Sections:
// 1. Imports
// 2. View Model / State
// 3. View Body
// 4. Runtime Wiring
// 5. Restart (Play Again)
//
// NOTE: Debug logging is controlled by DebugLog.isEnabled (default Off).

import SwiftUI
import SpriteKit

struct GameHostView: View {
    // Section 2: Dependencies (initial engine provided by parent; first run uses this instance)
    private let initialEngine: GameCoreEngine
    let activePlayerId: String

    // Section 2.1: Runtime-owned state
    @State private var engine: GameCoreEngine
    @State private var driver: FixedStepDriver? = nil
    @State private var scene: GameScene = GameScene()

    // Section 2.2: UI-visible run state (drives SwiftUI overlay controls)
    @State private var lastRunPhase: RunPhase = .playing

    @StateObject private var input = SwipeInputCollector()

    init(engine: GameCoreEngine, activePlayerId: String) {
        self.initialEngine = engine
        self.activePlayerId = activePlayerId
        _engine = State(initialValue: engine)
    }

    // Section 3: View
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                SpriteView(scene: scene)
                    .ignoresSafeArea()
                    .allowsHitTesting(lastRunPhase != .captured)
                    // Use simultaneous gestures so SpriteKit continues to receive taps.
                    .simultaneousGesture(
                        DragGesture(minimumDistance: input.minimumDistance, coordinateSpace: .local)
                            .onEnded { value in
                                input.handleDrag(translation: value.translation)
                            }
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 1.0)
                            .onEnded { _ in
                                // Flush debug log to Documents.
                                guard DebugLog.isEnabled else { return }
                                _ = DebugLog.flushToFile()
                            }
                    )

                // Section 3.1: SwiftUI "Play Again" overlay (reliable tap handling)
                // We intentionally render this in SwiftUI rather than SpriteKit to avoid gesture routing issues.
                if lastRunPhase == .captured {
                    VStack {
                        Spacer().frame(height: proxy.size.height * 0.20)
                        Button(action: {
                            restartRun(for: proxy.size)
                        }) {
                            Text("Play Again")
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                    .padding(.top, 0)
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .onAppear {
                // Section 4.0: Start (or restart) runtime for the current size.
                startRuntime(for: proxy.size)
            }
            .onChange(of: proxy.size) { newSize in
                // Keep GameCore sizing in sync.
                engine.setViewWidth(Double(newSize.width))
                engine.setViewHeight(Double(newSize.height))
                scene.size = newSize
            }
            .onDisappear {
                // Section 4.9: Stop runtime
                driver?.stop()
                driver = nil
            }
        }
    }

    // Section 4: Runtime Wiring
    private func startRuntime(for size: CGSize) {
        // Ensure any previous driver is stopped (safe no-op if nil).
        driver?.stop()
        driver = nil

        // Configure renderer sizing/scaling
        scene.size = size
        scene.scaleMode = .resizeFill

        // Apply UI-owned snapshot fields
        engine.setViewWidth(Double(size.width))
        engine.setViewHeight(Double(size.height))
        engine.setActivePlayerId(activePlayerId)

        // Wire callbacks
        let newDriver = FixedStepDriver(engine: engine)

        newDriver.onStateUpdated = { state in
            // Drive SpriteKit rendering
            scene.render(state: state)

            // Drive SwiftUI overlay state (main thread)
            DispatchQueue.main.async {
                self.lastRunPhase = state.runPhase
            }
        }
        newDriver.drainInputEvents = { input.drain() }

        // Route SpriteKit tap events into the same deterministic input queue.
        scene.onInputEvent = { event in
            input.enqueue(event)
        }

        // Note: Play Again is handled in SwiftUI overlay for reliable taps.
        scene.onPlayAgain = {
            // Keep wired for future use, but rely on SwiftUI overlay.
            restartRun(for: size)
        }

        driver = newDriver
        newDriver.start()

        if DebugLog.isEnabled {
            DebugLog.log("GameHostView.startRuntime(size=\(Int(size.width))x\(Int(size.height))) activePlayerId=\(activePlayerId)")
        }
    }

    // Section 5: Restart (Play Again)
    private func restartRun(for size: CGSize) {
        if DebugLog.isEnabled {
            DebugLog.log("GameHostView.restartRun() requested")
        }

        // 5.1 Stop driver first to prevent stepping while we swap state.
        driver?.stop()
        driver = nil

        // 5.2 Drain any queued input events so we don't carry gestures into the new run.
        _ = input.drain()

        // 5.2.1 Clear debug log on restart to avoid unbounded growth.
        DebugLog.clear()

        // 5.3 Reset UI overlay state.
        lastRunPhase = .playing

        // 5.4 Create a brand-new engine for a clean run.
        // We intentionally do NOT mutate the old engine's internal state because it is authoritative/private.
        let freshEngine = GameCoreEngine()
        engine = freshEngine

        // 5.5 Recreate the scene to reset node actions/animations and UI overlay state.
        let freshScene = GameScene()
        scene = freshScene

        // 5.6 Start runtime on the fresh engine/scene.
        startRuntime(for: size)
    }
}

// End of GameHostView.swift
