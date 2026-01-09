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
import UIKit

struct GameHostView: View {
    @Environment(\.dismiss) private var dismiss

    // Section 2: Dependencies (engine is a reference type; SwiftUI does not need to observe it)
    private let engine: GameCoreEngine
    let initialActivePlayerId: String

    // Section 2.1: Runtime-owned state
    @State private var driver: FixedStepDriver? = nil
    @State private var scene: GameScene = GameScene()

    // Section 2.1.1: Player selection (UI)
    // NOTE:
    // SwiftUI cannot reliably enumerate asset-catalog entries at runtime.
    // We maintain an explicit allowlist of candidate character IDs, then filter it
    // by checking for the presence of "<Id>_idle" in the bundle.
    private let candidatePlayerIds: [String] = ["Finley", "Sophia", "Isabella", "Charlotte"]
    @State private var selectedPlayerId: String = "Finley"

    // Section 2.1.2: Geometry tracking (used for restarts/auto-advance)
    @State private var lastKnownSize: CGSize = .zero

    // Section 2.2: UI-visible run state (drives SwiftUI overlay controls)
    @State private var currentLevel: Int = 1
    @State private var maxLevel: Int = 5
    @State private var currentPuppyId: String = "Lilly"

    @State private var lastRunPhase: RunPhase = .playing

    // Section 2.2.1: Capture gating (ensures animations can play before showing controls)
    @State private var postCaptureTime: Double = 0.0
    @State private var postCaptureDuration: Double = 1.0

    @StateObject private var input = SwipeInputCollector()

    // Section 2.3: Player list helpers (UI-only)
    private func availablePlayerIds() -> [String] { candidatePlayerIds }

    init(engine: GameCoreEngine, activePlayerId: String) {
        self.engine = engine
        self.initialActivePlayerId = activePlayerId
        _selectedPlayerId = State(initialValue: activePlayerId)
    }

    // Section 2.4: Shared post-capture UI styling
    // We standardize the "after capture" controls (Play Again, Character Selection, Next Level, Main Menu)
    // to ensure consistent visibility and tap affordance.
    private struct PostCapturePrimaryControlModifier: ViewModifier {
        @Environment(\.isEnabled) private var isEnabled

        // Tunables (kept private to avoid theme drift)
        private let font = Font.system(size: 22, weight: .bold, design: .monospaced)
        private let horizontalPadding: CGFloat = 24
        private let verticalPadding: CGFloat = 12
        private let cornerRadius: CGFloat = 10

        func body(content: Content) -> some View {
            content
                .font(font)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .foregroundStyle(Color.white)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.blue.opacity(isEnabled ? 1.0 : 0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        }
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
                if lastRunPhase == .captured && postCaptureTime >= postCaptureDuration {
                    VStack(spacing: 14) {
                        Spacer().frame(height: proxy.size.height * 0.18)

                        // Row 1: Play Again
                        Button(action: {
                            restartRun(for: proxy.size)
                        }) {
                            Text("Play Again")
                        }
                        .buttonStyle(.plain)
                        .modifier(PostCapturePrimaryControlModifier())

                        // Row 2: Character selection (under Play Again)
                        // Implemented as a Menu so it can share the same primary visual styling.
                        Menu {
                            ForEach(availablePlayerIds(), id: \.self) { id in
                                Button(action: {
                                    selectedPlayerId = id
                                }) {
                                    Text(id)
                                }
                            }
                        } label: {
                            Text("Character: \(selectedPlayerId)")
                        }
                        .buttonStyle(.plain)
                        .modifier(PostCapturePrimaryControlModifier())

                        // Row 3: Next Level
                        Button(action: {
                            // Advance only if we have not reached the level cap.
                            if currentLevel < maxLevel {
                                // Apply player selection for the next level as well.
                                engine.setActivePlayerId(selectedPlayerId)
                                engine.advanceToNextLevelAfterCapture()
                            }
                        }) {
                            Text(currentLevel < maxLevel ? "Next Level as \(selectedPlayerId)" : "Max Level")
                        }
                        .buttonStyle(.plain)
                        .modifier(PostCapturePrimaryControlModifier())
                        .disabled(currentLevel >= maxLevel)

                        // Row 4: Main Menu
                        Button(action: {
                            // Stop runtime and return to the prior screen.
                            driver?.stop()
                            driver = nil

                            // In some navigation setups GameHostView can be the root view, in which
                            // case dismiss() is a no-op. We still call it, but also emit a notification
                            // that parent views can optionally observe to force navigation back.
                            if DebugLog.isEnabled {
                                DebugLog.log("GameHostView.mainMenu() requested")
                            }

                            NotificationCenter.default.post(name: .runningFromPuppiesQuitRequested, object: nil)
                            dismiss()
                        }) {
                            Text("Main Menu")
                        }
                        .buttonStyle(.plain)
                        .modifier(PostCapturePrimaryControlModifier())

                        Spacer()
                    }
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .onAppear {
                // Section 4.0: Start (or restart) runtime for the current size.
                lastKnownSize = proxy.size
                startRuntime(for: proxy.size)
            }
            .onChange(of: proxy.size) { _, newSize in
                lastKnownSize = newSize
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

        // Capture the scene instance we are wiring to this driver. This prevents a rare but
        // impactful crash where a stopped driver can still deliver one last onStateUpdated
        // tick while SwiftUI has already swapped the @State `scene` for a fresh instance
        // during "Play Again".
        let activeScene = scene

        // Apply UI-owned snapshot fields
        engine.setViewWidth(Double(size.width))
        engine.setViewHeight(Double(size.height))
        engine.setActivePlayerId(selectedPlayerId)

        // Wire callbacks
        let newDriver = FixedStepDriver(engine: engine)

        newDriver.onStateUpdated = { [weak activeScene] state in
            // Drive SpriteKit rendering
            activeScene?.render(state: state)

            // Drive SwiftUI overlay state (main thread)
            DispatchQueue.main.async {
                self.lastRunPhase = state.runPhase
                self.currentLevel = state.currentLevel
                self.maxLevel = state.maxLevel
                self.currentPuppyId = state.activePuppyId
                self.postCaptureTime = state.postCaptureTime
                self.postCaptureDuration = state.postCaptureDuration
            }
        }
        newDriver.drainInputEvents = { input.drain() }

        // Route SpriteKit tap events into the same deterministic input queue.
        activeScene.onInputEvent = { event in
            input.enqueue(event)
        }

        // Note: Play Again is handled in SwiftUI overlay for reliable taps.
        activeScene.onPlayAgain = {
            // Keep wired for future use, but rely on SwiftUI overlay.
            restartRun(for: size)
        }

        driver = newDriver
        newDriver.start()

        if DebugLog.isEnabled {
            DebugLog.log("GameHostView.startRuntime(size=\(Int(size.width))x\(Int(size.height))) activePlayerId=\(selectedPlayerId)")
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

        // 5.4 Reset the existing engine deterministically (clears score/time, returns to Level 1).
        engine.resetRun(activePlayerId: selectedPlayerId)

        // 5.5 Recreate the scene to reset node actions/animations and caches.
        let freshScene = GameScene()
        scene = freshScene

        // 5.6 Start runtime on the reset engine + fresh scene.
        startRuntime(for: size)
    }
}


// Section 6: Notifications
extension Notification.Name {
    static let runningFromPuppiesQuitRequested = Notification.Name("RunningFromPuppies_QuitRequested")
}

// End of GameHostView.swift
