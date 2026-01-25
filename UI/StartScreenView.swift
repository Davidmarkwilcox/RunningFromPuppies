// StartScreenView.swift
// UI
// Launch/start screen for Running From Puppies.
// Displays background artwork, allows playable character selection (Finley/Sophia/Isabella/Charlotte),
// and starts gameplay. Also provides top-right toolbar access to Leaderboards and Settings.
//
// Interactions:
// - ContentView wraps this view in a NavigationStack (only when not playing).
// - Toolbar icons present translucent modal overlays for UI/LeaderboardsView and UI/SettingsView.
//
// Debug Mode: Off (set to true to emit console logs for UI navigation)
//
// Section 1: Imports

import SwiftUI

// Section 2: StartScreenView

struct StartScreenView: View {
    // Section 2.1: Debug toggle
    private let debugMode: Bool = false

    // Section 2.2: Overlay presentation state
    @State private var showLeaderboards: Bool = false
    @State private var showSettings: Bool = false

    // Section 2.3: Bindings
    @Binding var activePlayerId: String
    @Binding var isPlaying: Bool

    // Section 2.4: Player list (playable characters)
    // NOTE: Intentionally code-defined for now. Later, we can make this manifest-driven.
    private let playerIds: [String] = ["Finley", "Sophia", "Isabella", "Charlotte"]

    // Section 3: Body

    var body: some View {
        ZStack {
            // Section 3.1: Background artwork
            // Provide an image asset named "AppIconArt" (recommended), or replace this name.
            Image("AppIconArt")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            // Section 3.2: Dim overlay for readability
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .ignoresSafeArea()

            // Section 3.3: Foreground content
            VStack(spacing: 18) {
                Spacer()

                Text("Running from Puppies")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                // Section 3.4: Player picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Player Selection")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.95))

                    Picker("Player Selection", selection: $activePlayerId) {
                        ForEach(playerIds, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.black)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 24)

                // Section 3.5: Play button
                Button {
                    if debugMode { print("[StartScreenView] Play tapped") }
                    isPlaying = true
                } label: {
                    Text("Play")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.black)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.horizontal, 24)

                Spacer()
                Spacer()
            }

            // Section 3.6: Modal overlays (custom, translucent)
            if showLeaderboards {
                ModalOverlay(title: "Leaderboards", onClose: {
                    if debugMode { print("[StartScreenView] Closing Leaderboards overlay") }
                    showLeaderboards = false
                }) {
                    LeaderboardsView()
                }
                .transition(.opacity)
            }

            if showSettings {
                ModalOverlay(title: "Settings", onClose: {
                    if debugMode { print("[StartScreenView] Closing Settings overlay") }
                    showSettings = false
                }) {
                    SettingsView()
                }
                .transition(.opacity)
            }
        }
        // Section 4: Navigation / Toolbar
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Hide StartScreen toolbar items while an overlay is open
                if !showLeaderboards && !showSettings {
                    Button {
                        if debugMode { print("[StartScreenView] Leaderboards icon tapped") }
                        showLeaderboards = true
                    } label: {
                        Image(systemName: "trophy")
                            .foregroundStyle(.white)
                            .accessibilityLabel("Leaderboards")
                    }

                    Button {
                        if debugMode { print("[StartScreenView] Settings icon tapped") }
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.white)
                            .accessibilityLabel("Settings")
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showLeaderboards)
        .animation(.easeInOut(duration: 0.18), value: showSettings)
    }
}

// Section 98: Modal overlay helpers

private struct ModalOverlay<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            // Section 98.1: Dim layer that still reveals StartScreen artwork underneath.
            Rectangle()
                .fill(.black.opacity(0.35))
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            // Section 98.2: Container
            NavigationStack {
                content()
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { onClose() }
                        }
                    }
            }
            .frame(maxWidth: 560) // iPad-friendly while still OK on iPhone
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(radius: 20)
        }
    }
}

// End of StartScreenView.swift
