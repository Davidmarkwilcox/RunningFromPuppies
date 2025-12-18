// FixedStepDriver.swift
// Runtime
// Fixed-step simulation driver using CADisplayLink.

import Foundation
import QuartzCore

final class FixedStepDriver {
    private let engine: GameCoreEngine
    private let fixedDelta: Double = 1.0 / 60.0

    private var accumulator: Double = 0.0
    private var lastTimestamp: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var frameCounter: Int = 0
    private var lastLogTime: CFTimeInterval = 0

    var onStateUpdated: ((GameState) -> Void)?
    var drainInputEvents: (() -> [InputEvent])?

    init(engine: GameCoreEngine) {
        self.engine = engine
    }

    func start() {
        DebugLog.log("FixedStepDriver.start()")
        lastTimestamp = CACurrentMediaTime()
        displayLink = CADisplayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }

    func stop() {
        DebugLog.log("FixedStepDriver.stop()")
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(link: CADisplayLink) {
        let frameTime = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp

        frameCounter += 1
        if lastLogTime == 0 { lastLogTime = link.timestamp }

        // Log roughly every ~2 seconds (throttled)
        if (link.timestamp - lastLogTime) >= 2.0 {
            DebugLog.log("tick: frameTime=\(String(format: "%.4f", frameTime)) acc=\(String(format: "%.4f", accumulator))")
            lastLogTime = link.timestamp
        }
        
        accumulator += frameTime

        var stepsThisFrame = 0

        while accumulator >= fixedDelta {
            let events = drainInputEvents?() ?? []
            if !events.isEmpty {
                DebugLog.log("drainInputEvents(): \(events.count) event(s): \(events)")
            }

            engine.step(deltaTime: fixedDelta, inputEvents: events)

            accumulator -= fixedDelta
            stepsThisFrame += 1
        }

        // If we had to simulate multiple steps in one display frame, that implies hitching.
        if stepsThisFrame > 1 {
            DebugLog.log("HITCH: stepsThisFrame=\(stepsThisFrame)")
        }

        onStateUpdated?(engine.state)


        onStateUpdated?(engine.state)
    }
}

// End of FixedStepDriver.swift
