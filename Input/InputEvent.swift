// InputEvent.swift
// Input
// Canonical input events for Running from Puppies.
// Produced by input collectors (SwiftUI gesture adapters) and consumed by Runtime/GameCore.
//
// Section 1: Input Event Model

import Foundation

enum InputEvent: Equatable {
    case swipeLeft
    case swipeRight
    case swipeUp
    case swipeDown
    case tapPlayer
}

// End of InputEvent.swift
