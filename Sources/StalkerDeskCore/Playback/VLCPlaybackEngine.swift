//
//  VLCPlaybackEngine.swift
//  StalkerDeskCore
//
//  Optional fallback engine. Compiled only when VLCKit is linked, which keeps
//  the base app dependency-free while enabling raw MPEG-TS/MPEG-2 playback when
//  a VLCKit binary is available.
//
//  Integration options:
//  - Add VLCKit.xcframework to an Xcode target and set SWIFT_INCLUDE_PATHS.
//  - Use the CocoaPods "VLCKit" pod with an Xcode workspace.
//
//  VLCKit is LGPLv2.1-or-later; review its license and dynamic-linking terms
//  before distributing the app.
//

#if canImport(VLCKit)
import AppKit
import Foundation
import VLCKit

@MainActor
final class VLCPlaybackEngine: NSObject, PlaybackEngine {
    let kind: PlaybackEngineKind = .vlcKit
    weak var delegate: PlaybackEngineDelegate?
    let view: NSView = NSView()

    private let player = VLCMediaPlayer()
    private var lastState: PlaybackState = .idle
    private var startTime: Double?

    var pipAvailable: Bool { false }
    var pipActive: Bool { false }

    override init() {
        super.init()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        player.delegate = self
        player.drawable = view
    }

    func load(_ request: PlaybackRequest) {
        let media = VLCMedia(url: request.url)

        // libVLC options. Portals usually key streams off the MAG user agent and
        // referer; cookies are passed when the linked libVLC accepts the option.
        if let userAgent = request.headers["User-Agent"] {
            media.addOption(":http-user-agent=\(userAgent)")
        }
        if let referer = request.headers["Referer"] {
            media.addOption(":http-referrer=\(referer)")
        }
        if let cookie = request.headers["Cookie"] {
            media.addOption(":http-cookie=\(cookie)")
        }

        player.media = media
        startTime = request.startTime
        lastState = .preparing
        delegate?.engine(self, didChangeState: .preparing)
    }

    func play() {
        player.play()
        if let startTime, startTime > 1 {
            player.time = VLCTime(int: Int32(startTime * 1000))
        }
    }

    func pause() {
        if player.isPlaying {
            player.pause()
        }
    }

    func stop() {
        player.stop()
        player.media = nil
        lastState = .idle
        delegate?.engine(self, didChangeState: .idle)
    }

    func seek(to seconds: Double) {
        player.time = VLCTime(int: Int32(max(0, seconds) * 1000))
    }

    func setVolume(_ volume: Float) {
        player.audio?.volume = Int32(min(max(volume, 0), 1) * 100)
    }

    func setMuted(_ muted: Bool) {
        player.audio?.isMuted = muted
    }

    func setAspectRatio(_ ratio: PlayerAspectRatio) {
        // libVLC handles aspect ratio internally; the default renderer fits the
        // drawable. AVPlayer handles the richer fit/zoom modes.
    }

    func togglePictureInPicture() {
        // PiP requires a dedicated libVLC vout integration; unavailable here.
    }
}

extension VLCPlaybackEngine: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        switch player.state {
        case .opening, .buffering:
            report(.buffering)
        case .playing:
            report(.playing)
        case .paused:
            report(.paused)
        case .stopped:
            report(.idle)
        case .ended:
            report(.ended)
        case .error:
            let message = "VLCKit could not play this stream."
            report(.failed(message))
            delegate?.engine(self, didFail: message)
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let time = Double(player.time.intValue) / 1000
        let duration = Double(player.media?.length.intValue ?? 0) / 1000
        delegate?.engine(self, didUpdateTime: max(0, time), duration: max(0, duration))
    }

    private func report(_ state: PlaybackState) {
        guard state != lastState else { return }
        lastState = state
        delegate?.engine(self, didChangeState: state)
    }
}
#endif
