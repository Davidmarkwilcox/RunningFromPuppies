// SwipeInputCollector.swift
// SwipeInputCollector20260108-2052.swift
// Purpose: SwiftUI-facing swipe gesture translator that converts drag translations into canonical InputEvents.
//          This collector is consumed by FixedStepDriver (via drain) and ultimately GameCoreEngine (via step/apply).
//
// Sections:
// 1. Imports
// 2. SwipeInputCollector (queue + thresholds)
// 3. Drag classification (cardinal + diagonal)
// 4. End-of-file marker

// Section 1: Imports
import Foundation
import CoreGraphics
import Combine

// Section 2: Collector
final class SwipeInputCollector: ObservableObject {

    // ---------------------------------------------------------------------
    // Section 2.1: Configuration
    // ---------------------------------------------------------------------
    // Tunable thresholds. Keep conservative for MPS-1.
    var minimumDistance: CGFloat = 30.0
    var directionLockRatio: CGFloat = 1.3   // dominant axis must exceed the other by this ratio

    // ---------------------------------------------------------------------
    // Section 2.2: Internal queue
    // ---------------------------------------------------------------------
    private var queue: [InputEvent] = []
    private let lock = NSLock()

    // ---------------------------------------------------------------------
    // Section 2.3: Public API
    // ---------------------------------------------------------------------

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

    // ---------------------------------------------------------------------
    // Section 3: Drag classification
    // ---------------------------------------------------------------------

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
            return
        }

        if abs(dy) >= abs(dx) * directionLockRatio {
            // In iOS coordinate space, dragging up yields negative dy
            DebugLog.log("Swipe detected: \(dy < 0 ? "Up" : "Down") translation=(\(dx), \(dy))")
            enqueue(dy < 0 ? .swipeUp : .swipeDown)
            return
        }

        // -----------------------------------------------------------------
        // Section 3.1: Diagonal (Up-Left / Up-Right)
        // -----------------------------------------------------------------
        // Only accept *upward* diagonals for now.
        // - Both axes must clear minimumDistance to prevent accidental diagonals.
        // - Down-left / down-right remain ignored.
        guard dy < 0 else { return }
        guard abs(dx) >= minimumDistance, abs(dy) >= minimumDistance else { return }

        if dx < 0 {
            DebugLog.log("Swipe detected: Up-Left translation=(\(dx), \(dy))")
            enqueue(.swipeUpLeft)
        } else {
            DebugLog.log("Swipe detected: Up-Right translation=(\(dx), \(dy))")
            enqueue(.swipeUpRight)
        }
    }
}

// End of SwipeInputCollector.swift
