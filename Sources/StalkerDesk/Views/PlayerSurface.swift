//
//  PlayerSurface.swift
//  StalkerDesk
//
//  Bridges the coordinator's AppKit playback surface into SwiftUI.
//

import AppKit
import StalkerDeskCore
import SwiftUI

struct PlayerSurface: NSViewRepresentable {
    @ObservedObject var player: PlayerCoordinator
    var isActive: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = PlayerContainerView()
        if isActive {
            player.attachSurface(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isActive {
            player.attachSurface(nsView)
        }
    }

    func dismantleNSView(_ nsView: NSView, coordinator: Context) {
        player.detachSurface(nsView)
    }
}

final class PlayerContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
