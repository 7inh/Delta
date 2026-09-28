//
//  SettingsView.swift
//  Delta
//
//  Created by Caroline Moore on 3/31/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import SwiftUI

import DeltaCore
import Harmony

private struct SettingsBadge: View
{
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }
}

struct SettingsView: View
{
    @Environment(\.dismiss)
    private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ControlsSection()
                EmulationSection()
                OnlineMultiplayerSection()
                ServicesSection()
                MiscellaneousSection()
            }
            .safeAreaPadding(.top, 8)
            .navigationTitle("Settings")
            .toolbar {
                if #available(iOS 26, *)
                {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) {
                            // dismiss() skips presentationControllerDidDismiss, so explicitly sync on close.
                            SyncManager.shared.sync()
                            dismiss()
                        }
                    }
                }
                else
                {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            // dismiss() skips presentationControllerDidDismiss, so explicitly sync on close.
                            SyncManager.shared.sync()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Controls

private struct ControlsSection: View
{
    @SwiftUI.State
    private var gameControllerManager: ExternalGameControllerManager = .shared

    var body: some View {
        Section("Controls") {
            NavigationLink {
                ControllerSettingsView()
            } label: {
                SettingsRow(label: Text("Controllers"), systemImage: "gamecontroller", color: .purple) {
                    if !gameControllerManager.connectedControllers.isEmpty
                    {
                        Text("\(gameControllerManager.connectedControllers.count) Connected")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink {
                SkinSettingsView()
            } label: {
                SettingsRow(label: Text("Skins"), systemImage: "paintpalette", color: .pink)
            }

            NavigationLink {
                TouchHapticsView()
            } label: {
                SettingsRow(label: Text("Touch & Haptics"), systemImage: "hand.tap", color: .red)
            }

            NavigationLink {
                SwipeControlsSettingsView()
            } label: {
                SettingsRow(label: Text("Swipe Controls"), systemImage: "hand.draw", color: .orange)
            }
        }
    }
}

// MARK: - Emulation

private struct EmulationSection: View
{
    var body: some View {
        Section("Emulation") {
            NavigationLink {
                AudioSettingsView()
            } label: {
                SettingsRow(label: Text("Audio"), systemImage: "speaker.wave.2", color: .green)
            }

            NavigationLink {
                VideoSettingsView()
            } label: {
                SettingsRow(label: Text("Video"), systemImage: "display", color: .teal)
            }

            NavigationLink {
                CoresListView()
            } label: {
                SettingsRow(label: Text("Cores"), systemImage: "cpu", color: .cyan)
            }
        }
    }
}

// MARK: - Online Multiplayer

private struct OnlineMultiplayerSection: View
{
    var body: some View {
        Section {
            NavigationLink {
                OnlineMultiplayerView()
            } label: {
                SettingsRow(label: Text("Online Multiplayer"), systemImage: "globe", color: .orange)
            }
        }
    }
}

// MARK: - Online Multiplayer Detail

struct OnlineMultiplayerView: View
{
    @SwiftUI.State
    private var preferredWFCServer: String? = Settings.preferredWFCServer

    @SwiftUI.State
    private var isConfirmingReset: Bool = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    WFCServersView()
                } label: {
                    LabeledContent {
                        if let serverName = preferredServerName
                        {
                            Text(serverName)
                        }
                    } label: {
                        Text("WFC Server")
                    }
                }

                if preferredWFCServer != nil
                {
                    Button("Reset Online Settings", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .confirmationDialog("Are you sure you want to reset your online settings?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                        Button("Reset Online Settings", role: .destructive) {
                            WFCManager.shared.resetWFCConfiguration()
                        }
                    } message: {
                        Text("You may need to re-add any friend codes you’ve previously registered.")
                    }
                }
            } header: {
                Text("Nintendo DS")
            } footer: {
                Text("Choose the 3rd-party Nintendo WFC server Delta should use for online play in Nintendo DS games.")
            }
        }
        .navigationTitle("Online Multiplayer")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: Settings.didChangeNotification)) { notification in
            guard let name = notification.userInfo?[Settings.NotificationUserInfoKey.name] as? Settings.Name,
                  name == .preferredWFCServer else { return }

            preferredWFCServer = Settings.preferredWFCServer
        }
        .onAppear {
            preferredWFCServer = Settings.preferredWFCServer
        }
    }

    private var preferredServerName: String? {
        guard let preferredWFCServer else { return nil }

        if let servers = UserDefaults.standard.wfcServers, let knownServer = servers.first(where: { $0.dns == preferredWFCServer })
        {
            return knownServer.name
        }

        return preferredWFCServer
    }
}

// MARK: - Services

private struct ServicesSection: View
{
    @SwiftUI.State
    private var syncingServiceName: String? = Settings.syncingService?.localizedName
    
    @SwiftUI.State
    private var syncConflictsCount: Int = 0
    
    @SwiftUI.State
    private var isAccountConnected: Bool = SyncManager.shared.coordinator?.account != nil

    @SwiftUI.State
    private var retroAchievementsUsername: String? = Keychain.shared.retroAchievementsUsername

    var body: some View {
        Section {
            NavigationLink {
                SyncingServicesViewController.ViewRepresentable()
                    .ignoresSafeArea()
            } label: {
                SettingsRow(label: Text("Delta Sync"), systemImage: "arrow.triangle.2.circlepath", color: .indigo) {
                    if let name = syncingServiceName {
                        Text(name).foregroundStyle(.secondary)
                    }
                }
            }

            if isAccountConnected
            {
                NavigationLink {
                    SyncStatusViewController.ViewRepresentable()
                        .ignoresSafeArea()
                } label: {
                    SettingsRow(label: Text("Sync Status"), systemImage: "checkmark.icloud", color: .indigo) {
                        if syncConflictsCount > 0
                        {
                            SettingsBadge(text: "\(syncConflictsCount) conflicts", color: .red)
                        }
                        else
                        {
                            SettingsBadge(text: "Up-to-date", color: .green)
                        }
                    }
                }
            }

            NavigationLink {
                AchievementAccount()
            } label: {
                SettingsRow(label: Text("RetroAchievements"), systemImage: "medal", color: .indigo) {
                    if let username = retroAchievementsUsername {
                        Text(username).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Settings.didChangeNotification)) { notification in
            guard let name = notification.userInfo?[Settings.NotificationUserInfoKey.name] as? Settings.Name,
                  name == .syncingService else { return }
            
            syncingServiceName = Settings.syncingService?.localizedName
            isAccountConnected = SyncManager.shared.coordinator?.account != nil
            refreshSyncConflicts()
        }
        .onReceive(NotificationCenter.default.publisher(for: SyncCoordinator.didFinishSyncingNotification).receive(on: DispatchQueue.main)) { _ in
            refreshSyncConflicts()
        }
        .onReceive(NotificationCenter.default.publisher(for: AchievementsManager.didFinishAuthenticatingNotification).receive(on: DispatchQueue.main)) { _ in
            retroAchievementsUsername = Keychain.shared.retroAchievementsUsername
        }
        .onAppear {
            refreshSyncConflicts()
        }
    }

    private func refreshSyncConflicts()
    {
        do {
            let records = try SyncManager.shared.recordController?.fetchConflictedRecords() ?? []
            syncConflictsCount = records.count
        } catch {
            Logger.main.error("Failed to refresh sync conflicts. \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Patreon

// MARK: - Experimental, Minor, & Advanced

private struct MiscellaneousSection: View
{
    var body: some View {
        Section {
            NavigationLink {
                MinorSettingsView()
            } label: {
                SettingsRow(label: Text("Minor"), systemImage: "slider.horizontal.3", color: .gray)
            }

            NavigationLink {
                AdvancedSettingsView()
            } label: {
                SettingsRow(label: Text("Advanced"), systemImage: "gearshape", color: .gray)
            }
            
            NavigationLink {
                ExperimentalFeaturesView()
            } label: {
                SettingsRow(label: Text("Experimental"), systemImage: "flask", color: .gray)
            }

            NavigationLink {
                LicensesViewController.ViewRepresentable()
                    .ignoresSafeArea()
            } label: {
                Text("Software Licenses")
            }
        }
    }
}


#Preview {
    SettingsView()
}
