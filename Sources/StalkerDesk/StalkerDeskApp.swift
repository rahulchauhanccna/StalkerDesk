//
//  StalkerDeskApp.swift
//  StalkerDesk
//

import AppKit
import StalkerDeskCore
import SwiftUI

@main
struct StalkerDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var portalStore: PortalStore
    @StateObject private var appState: AppState

    init() {
        let store = PortalStore()
        _portalStore = StateObject(wrappedValue: store)
        _appState = StateObject(wrappedValue: AppState(portalStore: store))
    }

    var body: some Scene {
        WindowGroup("Arya IPTV Portal") {
            ContentView()
                .environmentObject(portalStore)
                .environmentObject(appState)
                .frame(minWidth: 1180, minHeight: 740)
        }
        .defaultSize(width: 1420, height: 880)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Playback") {
                Button("Play / Pause") {
                    appState.player.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Next Channel") {
                    appState.stepChannel(by: 1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.option])

                Button("Previous Channel") {
                    appState.stepChannel(by: -1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.option])

                Divider()

                Button("Toggle Fullscreen") {
                    appState.player.toggleFullscreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])

                Button("Picture in Picture") {
                    appState.player.togglePictureInPicture()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
