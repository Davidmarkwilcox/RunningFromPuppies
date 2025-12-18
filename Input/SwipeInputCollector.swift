// SwipeInputCollector.swift
// Input
// SwiftUI-facing swipe gesture translator that enqueues InputEvents.
// Interacts with ContentView (gesture attachment) and FixedStepDriver (event drain).
//
// Section 1: Collector

import Foundation
import CoreGraphics
import Combine

final class SwipeInputCollector: ObservableObject {

    // MARK: - Configuration
    // Tunable thresholds. Keep conservative for MPS-1.
    var minimumDistance: CGFloat = 30.0
    var directionLockRatio: CGFloat = 1.3   // dominant axis must exceed the other by this ratio

    // MARK: - Internal queue
    private var queue: [InputEvent] = []
    private let lock = NSLock()

    // MARK: - Public API

    /// Enqueue an event in a threadsafe manner.
    func enqueue(_ event: InputEvent) {
        lock.lock(); defer { lock.unlock() }
        queue.append(event)
    }

    /// Drains all queued events (FIFO) and returns them.
    /// Intended to be called by Runtime on the simulation tick.
    func drain() -> [InputEvent] {
        lock.lock(); defer { lock.unlock() }
        let events = queue
        queue.removeAll(keepingCapacity: true)
        return events
    }

    /// Convert a drag translation into a single directional swipe event, if it exceeds thresholds.
    /// This is "edge-triggered": one drag -> at most one event.
    func handleDrag(translation: CGSize) {
        let dx = translation.width
        let dy = translation.height

        // Require meaningful movement
        guard abs(dx) >= minimumDistance || abs(dy) >= minimumDistance else { return }

        // Determine dominant axis, with ratio-based direction lock
        if abs(dx) >= abs(dy) * directionLockRatio {
            DebugLog.log("Swipe detected: \(dx < 0 ? "Left" : "Right") translation=(\(dx), \(dy))")
            enqueue(dx < 0 ? .swipeLeft : .swipeRight)
        } else if abs(dy) >= abs(dx) * directionLockRatio {
            // In iOS coordinate space, dragging up yields negative dy
            DebugLog.log("Swipe detected: \(dy < 0 ? "Up" : "Down") translation=(\(dx), \(dy))")
            enqueue(dy < 0 ? .swipeUp : .swipeDown)
        } else {
            // Ambiguous diagonal; ignore for now to avoid accidental inputs.
            return
        }
    }
}

// End of SwipeInputCollector.swift
