//
//  FullscreenWindowController.swift
//  StalkerDesk
//
//  A dedicated borderless player window that covers the active screen. This is
//  more reliable than toggling AppKit's native fullscreen state machine while
//  SwiftUI is swapping player surfaces, and it maps directly to a tvOS
//  full-screen player presentation later.
//

import AppKit
import StalkerDeskCore
import SwiftUI

@MainActor
final class FullscreenWindowController: NSObject {
    private let player: PlayerCoordinator
    private weak var appState: AppState?
    private var window: NSWindow?
    private weak var previousKeyWindow: NSWindow?
    private var previousPresentationOptions: NSApplication.PresentationOptions = []
    private var escapeMonitor: Any?

    init(player: PlayerCoordinator, appState: AppState) {
        self.player = player
        self.appState = appState
        super.init()
    }

    var isPresented: Bool { window != nil }

    func toggle() {
        if window == nil {
            show()
        } else {
            close()
        }
    }

    private func show() {
        guard window == nil, let appState else { return }
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return }

        previousKeyWindow = NSApp.keyWindow
        previousPresentationOptions = NSApp.presentationOptions

        let root = FullscreenPlayerView(player: player) { [weak self] in
            self?.close()
        }
        .environmentObject(appState)

        let hosting = NSHostingController(rootView: root)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.styleMask = [.borderless]
        newWindow.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        newWindow.backgroundColor = .black
        newWindow.isOpaque = true
        newWindow.hasShadow = false
        newWindow.isMovable = false
        newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newWindow.setFrame(screen.frame, display: true)

        window = newWindow
        player.setFullscreenPresentationActive(true)
        NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    self?.close()
                }
                return nil
            }
            return event
        }

        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard let window else { return }

        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }

        player.setFullscreenPresentationActive(false)
        window.orderOut(nil)
        window.contentViewController = nil
        self.window = nil

        NSApp.presentationOptions = previousPresentationOptions
        if let previousKeyWindow {
            previousKeyWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        player.restorePrimarySurface()
    }
}
