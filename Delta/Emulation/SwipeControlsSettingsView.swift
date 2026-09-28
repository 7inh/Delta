//
//  SwipeControlsSettingsView.swift
//  Delta
//
//  Created by Tran Quoc Linh on 9/28/26.
//

import SwiftUI

import DeltaFeatures

struct SwipeControlsSettingsView: View
{
    private var feature: Feature<SwipeControlsOptions, Bool> {
        return Settings.features.swipeControls
    }

    private var isEnabled: Binding<Bool>
    {
        return Binding(get: { self.feature.isEnabled },
                       set: { self.feature.isEnabled = $0 })
    }

    var body: some View
    {
        Form
        {
            Section
            {
                Toggle("Swipe Controls", isOn: self.isEnabled)
            } footer: {
                Text("Replace on-screen buttons with swipe gestures. Start, Select and Menu buttons remain tappable.")
            }

            if self.isEnabled.wrappedValue
            {
                self.gesturesSection
                self.buttonsSection
                self.autofireSection
                self.feedbackSection

                Section("How to Play")
                {
                    VStack(alignment: .leading, spacing: 6)
                    {
                        Text("• Swipe left/right to run — keeps going until you swipe the other way or tap to stop")
                        Text("• Tap the opposite side while running to turn instantly")
                        Text("• Swipe up to jump (hold to jump longer)")
                        Text("• Autofire presses the fire button for you")
                        Text("• Double-tap to toggle autofire on/off")
                        Text("• Tap Start/Select/Menu normally — they fall through to the controller skin")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Swipe Controls")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections -

    private var gesturesSection: some View
    {
        Section("Gestures")
        {
            self.pickerRow("Layout", values: SwipeControlLayout.allCases,
                           get: { self.feature.layout },
                           set: { self.feature.layout = $0 })

            self.pickerRow("Direction Mode", values: SwipeDirectionMode.allCases,
                           get: { self.feature.directionMode },
                           set: { self.feature.directionMode = $0 })

            self.toggleRow("8-Way Directions",
                           get: { self.feature.isEightWayEnabled },
                           set: { self.feature.isEightWayEnabled = $0 })

            self.pickerRow("Swipe Up", values: SwipeUpAction.allCases,
                           get: { self.feature.swipeUpAction },
                           set: { self.feature.swipeUpAction = $0 })

            self.pickerRow("Swipe Down", values: SwipeDownAction.allCases,
                           get: { self.feature.swipeDownAction },
                           set: { self.feature.swipeDownAction = $0 })

            self.pickerRow("Swipe Sensitivity", values: [12, 16, 20, 26, 34],
                           get: { self.feature.swipeThreshold },
                           set: { self.feature.swipeThreshold = $0 })

            self.toggleRow("Tap Opposite Side to Turn",
                           get: { self.feature.isTapOppositeSideToTurnEnabled },
                           set: { self.feature.isTapOppositeSideToTurnEnabled = $0 })
        }
    }

    private var buttonsSection: some View
    {
        Section("Buttons")
        {
            self.pickerRow("Jump Button", values: SwipeButton.allCases,
                           get: { self.feature.jumpButton },
                           set: { self.feature.jumpButton = $0 })

            self.pickerRow("Fire Button", values: SwipeButton.allCases,
                           get: { self.feature.fireButton },
                           set: { self.feature.fireButton = $0 })
        }
    }

    private var autofireSection: some View
    {
        Section
        {
            self.toggleRow("Always Fire",
                           get: { self.feature.isAutofireAlwaysEnabled },
                           set: { self.feature.isAutofireAlwaysEnabled = $0 })

            self.toggleRow("Double-Tap Toggles Autofire",
                           get: { self.feature.isDoubleTapToggleEnabled },
                           set: { self.feature.isDoubleTapToggleEnabled = $0 })

            self.pickerRow("Fire Rate", values: Array(stride(from: 2, through: 15, by: 1)),
                           get: { self.feature.autofireRate },
                           set: { self.feature.autofireRate = $0 })

            self.pickerRow("Jump Duration", values: [4, 6, 8, 12, 16, 24, 30],
                           get: { self.feature.jumpPulseFrames },
                           set: { self.feature.jumpPulseFrames = $0 })
        } header: {
            Text("Autofire")
        } footer: {
            if self.feature.isAutofireAlwaysEnabled
            {
                Text("Autofire is active whenever the game is running. Double-tap (if enabled) turns it off temporarily.")
            }
            else if self.feature.isDoubleTapToggleEnabled
            {
                Text("Double-tap the controller area to turn autofire on or off.")
            }
            else
            {
                Text("Autofire is currently off.")
            }
        }
    }

    private var feedbackSection: some View
    {
        Section("Feedback")
        {
            self.toggleRow("Show Hints",
                           get: { self.feature.showsHints },
                           set: { self.feature.showsHints = $0 })

            self.toggleRow("Haptics",
                           get: { self.feature.isHapticsEnabled },
                           set: { self.feature.isHapticsEnabled = $0 })
        }
    }

    // MARK: - Rows -

    private func toggleRow(_ label: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> some View
    {
        return Toggle(label, isOn: Binding(get: get, set: set))
    }

    private func pickerRow<Value: LocalizedOptionValue>(_ label: String, values: some Collection<Value>, get: @escaping () -> Value, set: @escaping (Value) -> Void) -> some View
    {
        return Picker(label, selection: Binding(get: get, set: set))
        {
            ForEach(Array(values), id: \.self)
            { value in
                value.localizedDescription.tag(value)
            }
        }
    }
}

// MARK: - Preview -

#Preview
{
    NavigationStack
    {
        SwipeControlsSettingsView()
    }
}
