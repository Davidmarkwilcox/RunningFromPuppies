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
// IMPORTANT:
// Starting gameplay from the Start Screen must always begin a fresh run, even if the
// parent navigation stack reuses the same GameCoreEngine instance. We enforce this by
// performing a one-time deterministic reset the first time this GameHostView instance
// appears.
// Sections:
// 1. Imports
// 2. View Model / State
// 3. View Body
// 4. Runtime Wiring
// 5. Restart (Play Again)
//
// NOTE: Debug logging is controlled by DebugLog.isEnabled (default Off).

import SwiftUI
import Foundation
import CoreData
import SpriteKit
import UIKit

struct GameHostView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    // Section 2.0.1: Global leaderboard identity (from Settings).
    @AppStorage("globalDisplayName") private var globalDisplayName: String = ""

    // Section 2: Dependencies (engine is a reference type; SwiftUI does not need to observe it)
    private let engine: GameCoreEngine
    let initialActivePlayerId: String

    // Section 2.1: Runtime-owned state
    @State private var driver: FixedStepDriver? = nil
    @State private var scene: GameScene = GameScene()

    // Section 2.1.0: Fresh-run gating
    // SwiftUI navigation can sometimes reuse the same GameCoreEngine instance across
    // screen transitions. To guarantee that tapping "Play" always starts a new run,
    // we perform a single deterministic reset the first time this GameHostView instance
    // appears.
    @State private var hasInitializedFreshRun: Bool = false

    // Section 2.1.1: Player selection (UI)
    // NOTE:
    // SwiftUI cannot reliably enumerate asset-catalog entries at runtime.
    // We maintain an explicit allowlist of candidate character IDs, then filter it
    // by checking for the presence of "<Id>_idle" in the bundle.
    private let candidatePlayerIds: [String] = ["Finley", "Sophia", "Isabella", "Charlotte"]
    @State private var selectedPlayerId: String = "Finley"

    // Section 2.1.1.1: Active run player (immutable for the current run)
    // We allow selecting a different character *for the next run/level* via the post-capture UI.
    // To avoid mis-attributing scores, we snapshot the active player at run start.
    @State private var activeRunPlayerId: String = "Finley"

    // Section 2.1.2: Geometry tracking (used for restarts/auto-advance)
    @State private var lastKnownSize: CGSize = .zero

    // Section 2.2: UI-visible run state (drives SwiftUI overlay controls)
    @State private var currentLevel: Int = 1
    @State private var maxLevel: Int = 5
    @State private var currentPuppyId: String = "Lilly"

    // Section 2.2.0: Score tracking (for local leaderboards)
    @State private var currentScore: Int = 0
    @State private var runElapsedTime: Double = 0.0

    // Section 2.2.0.1: Session-best tracking (best score achieved during the run session)
    @State private var sessionBestScore: Int = 0
    @State private var sessionBestLevel: Int = 1
    @State private var sessionBestElapsedTime: Double = 0.0

    // Section 2.2.0.2: Recording guard
    @State private var didRecordLocalScoreForThisRunEnd: Bool = false

    // Section 2.2.0.3: Global submission guard (prevent repeat submits while on post-capture screen)
    @State private var didAttemptGlobalSubmitForThisRunEnd: Bool = false

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
        _activeRunPlayerId = State(initialValue: activePlayerId)
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
                                // Finalize the just-ended run before advancing.
                                recordLocalScoreIfNeeded(force: true)
                                attemptGlobalSubmitIfNeeded(force: true)

                                // Apply the selected player for the next level.
                                activeRunPlayerId = selectedPlayerId
                                engine.setActivePlayerId(activeRunPlayerId)
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
                            // Record the best score observed during this run session (once),
                            // then stop runtime and request navigation back.
                            recordLocalScoreIfNeeded(force: true)
                            attemptGlobalSubmitIfNeeded(force: true)

                            driver?.stop()
                            driver = nil

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

                // Ensure we start a fresh run the first time this view instance appears.
                ensureFreshRunOnFirstAppear(for: proxy.size)

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
    /// Ensures a deterministic "fresh run" when gameplay is entered from the Start Screen.
    ///
    /// Rationale:
    /// Some parent navigation setups retain the same GameCoreEngine instance when the user
    /// returns to the Start Screen via "Main Menu". If we simply re-present GameHostView and
    /// call startRuntime(), the engine can resume from the prior capture coordinates.
    ///
    /// This method enforces a single reset the first time *this* GameHostView instance appears.
    /// It does NOT run on subsequent onAppear events (e.g., background/foreground), and it does
    /// not interfere with "Next Level" which advances within the existing run.
    private func ensureFreshRunOnFirstAppear(for size: CGSize) {
        guard hasInitializedFreshRun == false else { return }
        hasInitializedFreshRun = true

        if DebugLog.isEnabled {
            DebugLog.log("GameHostView.ensureFreshRunOnFirstAppear() -> forcing resetRun(activePlayerId=\(activeRunPlayerId))")
        }

        // Stop any runtime (should typically be nil on first show, but safe).
        driver?.stop()
        driver = nil

        // Drain any queued input so we don't replay gestures into the new run.
        _ = input.drain()

        // Clear debug log on fresh-start for consistency with Play Again.
        DebugLog.clear()

        // Reset UI overlay state.
        lastRunPhase = .playing
        postCaptureTime = 0.0
        postCaptureDuration = 1.0

        // Reset score/session metrics
        currentScore = 0
        runElapsedTime = 0.0
        sessionBestScore = 0
        sessionBestLevel = 1
        sessionBestElapsedTime = 0.0
        didRecordLocalScoreForThisRunEnd = false
        didAttemptGlobalSubmitForThisRunEnd = false

        // Reset the engine deterministically back to Level 1 and spawn positions.
        activeRunPlayerId = selectedPlayerId
        engine.resetRun(activePlayerId: activeRunPlayerId)

        // Recreate the scene to discard any lingering SpriteKit node state/actions.
        scene = GameScene()
        scene.size = size
        scene.scaleMode = .resizeFill
    }

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
        engine.setActivePlayerId(activeRunPlayerId)

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
                self.currentScore = state.score
                self.runElapsedTime = state.elapsedTime

                // Track the best score observed during this run session.
                // If score improves, capture the level and elapsed time at that moment.
                if state.score > self.sessionBestScore {
                    self.sessionBestScore = state.score
                    self.sessionBestLevel = state.currentLevel
                    self.sessionBestElapsedTime = state.elapsedTime
                }

                // Auto-run end actions once the capture window has completed.
                self.handleAutoRunEndActionsIfNeeded()
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
            DebugLog.log("GameHostView.startRuntime(size=\(Int(size.width))x\(Int(size.height))) activePlayerId=\(activeRunPlayerId)")
        }
    }



    // Section 4.9: Auto Run-End Actions
    private func handleAutoRunEndActionsIfNeeded() {
        // Conditions are enforced inside the individual helpers.
        recordLocalScoreIfNeeded(force: false)
        attemptGlobalSubmitIfNeeded(force: false)
    }

    // Section 4.10: Local Scoreboard Recording
    private func recordLocalScoreIfNeeded(force: Bool = false) {
        // Goal:
        // Record only ONE entry per run session (the best score achieved during the session),
        // rather than recording at each level-end capture.
        //
        // When force == true, we record regardless of post-capture timers (used for Play Again / Main Menu taps).
        // When force == false, we only record once the run is fully ended (captured and post-capture duration elapsed).

        if !force {
            guard lastRunPhase == .captured else { return }
            guard postCaptureTime >= postCaptureDuration else { return }
        }

        guard !didRecordLocalScoreForThisRunEnd else { return }
        didRecordLocalScoreForThisRunEnd = true

        // Defensive: if sessionBestScore never updated, fall back to current snapshot values.
        let bestScore = max(sessionBestScore, currentScore)
        let bestLevel = (sessionBestScore >= currentScore) ? sessionBestLevel : currentLevel
        let bestElapsed = (sessionBestScore >= currentScore) ? sessionBestElapsedTime : runElapsedTime

        do {
            let store = CoreDataLocalScoreboardStore(context: viewContext)
            try store.recordRun(
                playerId: activeRunPlayerId,
                levelNumber: Int16(bestLevel),
                score: Int64(bestScore),
                durationSeconds: bestElapsed,
                endedAt: Date(),
                rulesetVersion: "v1"
            )

            if DebugLog.isEnabled {
                DebugLog.log("LOCAL_SCORE_RECORDED: player=\(activeRunPlayerId) level=\(bestLevel) score=\(bestScore) duration=\(String(format: "%.2f", bestElapsed))")
            }
        } catch {
            if DebugLog.isEnabled {
                DebugLog.log("LOCAL_SCORE_RECORD_ERROR: \(error)")
            }
        }
    }

    // Section 4.11: Global Leaderboard Submission
    private func attemptGlobalSubmitIfNeeded(force: Bool = false) {
        // Goal:
        // Submit only ONE global entry per run session (the best score observed during the session).
        // Never block gameplay flow; failures are ignored (optionally debug-logged).

        // If the user hasn't set a global display name, do not submit.
        let trimmedName = globalDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if !force {
            guard lastRunPhase == .captured else { return }
            guard postCaptureTime >= postCaptureDuration else { return }
        }

        guard !didAttemptGlobalSubmitForThisRunEnd else { return }
        didAttemptGlobalSubmitForThisRunEnd = true

        // Defensive: if sessionBestScore never updated, fall back to current snapshot values.
        let bestScore = Int64(max(sessionBestScore, currentScore))
        let bestLevel = (sessionBestScore >= currentScore) ? sessionBestLevel : currentLevel
        let bestElapsed = (sessionBestScore >= currentScore) ? sessionBestElapsedTime : runElapsedTime

        Task {
            do {
                let service = CloudKitLeaderboardService()
                let didSubmit = try await service.submitIfNewBest(
                    displayName: trimmedName,
                    playerId: activeRunPlayerId,
                    levelNumber: bestLevel,
                    score: bestScore,
                    durationSeconds: bestElapsed,
                    endedAt: Date()
                )

                if DebugLog.isEnabled {
                    DebugLog.log("GLOBAL_SCORE_SUBMIT: attempted=1 submitted=\(didSubmit) name=\(trimmedName) player=\(activeRunPlayerId) level=\(bestLevel) score=\(bestScore) duration=\(String(format: "%.2f", bestElapsed))")
                }
            } catch {
                if DebugLog.isEnabled {
                    DebugLog.log("GLOBAL_SCORE_SUBMIT_ERROR: \(error)")
                }
            }
        }
    }

    // Section 5: Restart (Play Again)
    private func restartRun(for size: CGSize) {
        if DebugLog.isEnabled {
            DebugLog.log("GameHostView.restartRun() requested")
        }

        // Record best score for this run session before we reset.
        recordLocalScoreIfNeeded(force: true)
        attemptGlobalSubmitIfNeeded(force: true)

        // 5.1 Stop driver first to prevent stepping while we swap state.
        driver?.stop()
        driver = nil

        // 5.2 Drain any queued input events so we don't carry gestures into the new run.
        _ = input.drain()

        // 5.2.1 Clear debug log on restart to avoid unbounded growth.
        DebugLog.clear()

        // 5.3 Reset UI overlay state.
        lastRunPhase = .playing
        postCaptureTime = 0.0

        // Reset score/session metrics
        currentScore = 0
        runElapsedTime = 0.0
        sessionBestScore = 0
        sessionBestLevel = 1
        sessionBestElapsedTime = 0.0
        didAttemptGlobalSubmitForThisRunEnd = false
        didRecordLocalScoreForThisRunEnd = false

        // 5.4 Snapshot the selected player for the new run.
        activeRunPlayerId = selectedPlayerId

        // 5.5 Reset the existing engine deterministically (clears score/time, returns to Level 1).
        engine.resetRun(activePlayerId: activeRunPlayerId)

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
