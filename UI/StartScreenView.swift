// StartScreenView.swift
// UI
// Launch/start screen for Running from Puppies.
// Displays background artwork, allows player selection, and starts gameplay.
//
// Section 1: Imports

import SwiftUI

struct StartScreenView: View {
    // Section 2: Bindings
    @Binding var activePlayerId: String
    @Binding var isPlaying: Bool

    // Section 3: Player list (MPS-3)
    // NOTE: This is intentionally code-defined for now. Later, we can make this manifest-driven.
    private let playerIds: [String] = ["Finley", "Sophia", "Isabella", "Charlotte"]

    var body: some View {
        ZStack {
            // Section 4: Background artwork
            // Provide an image asset named "AppIconArt" (recommended), or replace this name.
            Image("AppIconArt")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            // Dim overlay for readability
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                // Section 5: Title
                Text("Running from Puppies")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                // Section 6: Player picker
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
                    .tint(.black) // affects the menu control tint on many OS versions
                    .foregroundStyle(.black) // selected value text
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 24)

                // Section 7: Play button
                Button {
                    // Start gameplay
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
        }
    }
}

// End of StartScreenView.swift
