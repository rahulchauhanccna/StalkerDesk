//
//  PlayerCoordinator.swift
//  StalkerDeskCore
//
//  Owns the playback engine, injects Stalker HTTP headers, handles AVPlayer ->
//  VLCKit fallback, PiP, fullscreen, aspect ratios and player keyboard shortcuts.
//
//  AVPlayer is the primary engine. VLCKit support is compiled in when the
//  optional VLCKit framework is linked (see VLCPlaybackEngine.swift).
//

import AppKit
import AVKit
import Combine
import Foundation

// MARK: - Public playback types

public enum PlaybackState: Equatable, Sendable {
    case idle
    case preparing
    case buffering
    case playing
    case paused
    case failed(String)
    case ended

    public var isPlaying: Bool {
        self == .playing
    }

    public var isActive: Bool {
        switch self {
        case .idle, .failed, .ended: return false
        default: return true
        }
    }

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Tuning"
        case .buffering: return "Buffering"
        case .playing: return "Live"
        case .paused: return "Paused"
        case .failed: return "Playback error"
        case .ended: return "Ended"
        }
    }
}

public enum PlayerAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case sixteenNine
    case fit
    case zoom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sixteenNine: return "16:9"
        case .fit: return "Fit"
        case .zoom: return "Zoom"
        }
    }

    public var symbolName: String {
        switch self {
        case .sixteenNine: return "rectangle.ratio.16.to.9"
        case .fit: return "arrow.down.right.and.arrow.up.left"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        }
    }
}

// MARK: - Engine protocol

@MainActor
protocol PlaybackEngine: AnyObject {
    var kind: PlaybackEngineKind { get }
    var view: NSView { get }
    var delegate: PlaybackEngineDelegate? { get set }
    var pipAvailable: Bool { get }
    var pipActive: Bool { get }

    func load(_ request: PlaybackRequest)
    func play()
    func pause()
    func stop()
    func seek(to seconds: Double)
    func setVolume(_ volume: Float)
    func setMuted(_ muted: Bool)
    func setAspectRatio(_ ratio: PlayerAspectRatio)
    func togglePictureInPicture()
}

@MainActor
protocol PlaybackEngineDelegate: AnyObject {
    func engine(_ engine: PlaybackEngine, didChangeState state: PlaybackState)
    func engine(_ engine: PlaybackEngine, didUpdateTime time: Double, duration: Double)
    func engine(_ engine: PlaybackEngine, didChangePiP active: Bool, available: Bool)
    func engine(_ engine: PlaybackEngine, didFail error: String)
}

// MARK: - Keyboard

private enum PlayerKeyCommand {
    case nextChannel
    case previousChannel
    case playPause
    case mute
    case fullscreen
    case pictureInPicture
    case seekForward
    case seekBackward

    init?(event: NSEvent) {
        // Never steal text editing or shortcuts that include command/control.
        if let responder = event.window?.firstResponder, responder is NSTextView {
            return nil
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return nil }

        switch event.keyCode {
        case 126: self = .nextChannel       // up arrow
        case 125: self = .previousChannel   // down arrow
        case 49: self = .playPause          // space
        case 3: self = .fullscreen          // F
        case 46: self = .mute               // M
        case 35: self = .pictureInPicture   // P
        case 124: self = .seekForward       // right arrow
        case 123: self = .seekBackward      // left arrow
        default: return nil
        }
    }
}

// MARK: - Coordinator

@MainActor
public final class PlayerCoordinator: NSObject, ObservableObject {
    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var engineKind: PlaybackEngineKind = .avPlayer
    @Published public private(set) var aspectRatio: PlayerAspectRatio = .fit
    @Published public private(set) var isPiPAvailable = false
    @Published public private(set) var isPiPActive = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var isMuted = false
    @Published public private(set) var volume: Double = 1.0
    @Published public private(set) var currentRequest: PlaybackRequest?
    @Published public private(set) var isLive = true
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var fallbackNotice: String?
    @Published public private(set) var isFullScreen = false

    /// Channel navigation hooks wired by AppState.
    public var onNextChannel: (() -> Void)?
    public var onPreviousChannel: (() -> Void)?

    /// Injected by the app to present a dedicated borderless fullscreen window.
    /// When nil, falls back to the host window's native fullscreen.
    public var onToggleFullscreen: (() -> Void)?

    /// User-selected engine policy. Automatic prefers AVPlayer for HLS/MP4 and
    /// VLCKit for raw MPEG-TS when VLCKit is linked.
    public var preferredEngine: PlaybackEnginePreference = .automatic

    private var engine: PlaybackEngine?
    private var surfaceContainer: NSView?
    private var fallbackAttempted = false
    private var keyboardMonitor: Any?
    private weak var hostWindow: NSWindow?
    private weak var primarySurfaceContainer: NSView?

    public override init() {
        super.init()
    }

    deinit {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
    }

    // MARK: Public control

    public func play(_ request: PlaybackRequest) {
        currentRequest = request
        isLive = request.isLive
        fallbackAttempted = false
        errorMessage = nil
        fallbackNotice = nil
        currentTime = 0
        duration = 0
        state = .preparing

        let desired = preferredEngine(for: request)
        startEngine(kind: desired, request: request)
    }

    public func stop() {
        engine?.stop()
        engine?.view.removeFromSuperview()
        engine?.delegate = nil
        engine = nil
        currentRequest = nil
        state = .idle
        currentTime = 0
        duration = 0
        isPiPAvailable = false
        isPiPActive = false
    }

    public func togglePlayPause() {
        guard let engine else { return }
        switch state {
        case .playing, .buffering:
            engine.pause()
        case .paused, .ended:
            engine.play()
        default:
            break
        }
    }

    public func toggleMute() {
        isMuted.toggle()
        engine?.setMuted(isMuted)
    }

    public func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        isMuted = volume == 0
        engine?.setVolume(Float(volume))
        engine?.setMuted(isMuted)
    }

    public func setAspectRatio(_ ratio: PlayerAspectRatio) {
        aspectRatio = ratio
        engine?.setAspectRatio(ratio)
    }

    public func seek(to seconds: Double) {
        engine?.seek(to: seconds)
    }

    public func seek(by delta: Double) {
        let target = min(max(currentTime + delta, 0), duration > 0 ? duration : currentTime + delta)
        engine?.seek(to: target)
    }

    public func togglePictureInPicture() {
        engine?.togglePictureInPicture()
    }

    public func toggleFullscreen() {
        if let onToggleFullscreen {
            onToggleFullscreen()
            return
        }
        let window = hostWindow ?? surfaceContainer?.window ?? NSApp.keyWindow
        window?.toggleFullScreen(nil)
    }

    public func exitFullscreen() {
        if let onToggleFullscreen {
            onToggleFullscreen()
            return
        }
        let window = hostWindow ?? surfaceContainer?.window ?? NSApp.keyWindow
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    /// Called by the fullscreen window presenter so views can deactivate the
    /// in-page player surface while the dedicated player window owns it.
    public func setFullscreenPresentationActive(_ active: Bool) {
        if isFullScreen != active {
            isFullScreen = active
        }
    }

    public func setPreferredEngine(_ preference: PlaybackEnginePreference) {
        preferredEngine = preference
        guard let request = currentRequest else { return }
        play(request)
    }

    /// Begin listening for player keyboard shortcuts. Arrow keys change
    /// channels while the player is on screen.
    public func beginKeyboardMonitoring(in window: NSWindow? = nil) {
        hostWindow = window ?? NSApp.keyWindow
        guard keyboardMonitor == nil else { return }

        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let command = PlayerKeyCommand(event: event) else {
                return event
            }
            Task { @MainActor in
                self.perform(command: command)
            }
            return nil
        }
    }

    public func stopKeyboardMonitoring() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
        keyboardMonitor = nil
    }

    /// Attach the current engine's view to the SwiftUI-hosted container. Called
    /// from NSViewRepresentable on creation and on every update.
    public func attachSurface(_ view: NSView) {
        surfaceContainer = view
        if !isFullScreen {
            primarySurfaceContainer = view
        }
        attachEngineViewIfNeeded()
    }

    public func detachSurface(_ view: NSView) {
        guard surfaceContainer === view else { return }
        engine?.view.removeFromSuperview()
        surfaceContainer = nil
    }

    /// Reattach the player to the normal browse surface after leaving the
    /// fullscreen overlay.
    public func restorePrimarySurface() {
        guard let primarySurfaceContainer else { return }
        surfaceContainer = primarySurfaceContainer
        attachEngineViewIfNeeded()
    }

    // MARK: Engine selection

    private func preferredEngine(for request: PlaybackRequest) -> PlaybackEngineKind {
        switch request.preferredEngine {
        case .avPlayer:
            return .avPlayer
        case .vlcKit:
            #if canImport(VLCKit)
            return .vlcKit
            #else
            return .avPlayer
            #endif
        case .automatic:
            #if canImport(VLCKit)
            if PlaybackHeuristics.prefersVLCKit(for: request.url) {
                return .vlcKit
            }
            #endif
            return .avPlayer
        }
    }

    private func startEngine(kind: PlaybackEngineKind, request: PlaybackRequest) {
        if let previous = engine {
            previous.delegate = nil
            previous.stop()
            previous.view.removeFromSuperview()
        }

        let next: PlaybackEngine
        switch kind {
        case .avPlayer:
            next = AVPlayerEngine()
        case .vlcKit:
            #if canImport(VLCKit)
            next = VLCPlaybackEngine()
            #else
            next = AVPlayerEngine()
            #endif
        }

        engine = next
        engineKind = next.kind
        next.delegate = self
        next.setVolume(Float(volume))
        next.setMuted(isMuted)
        next.setAspectRatio(aspectRatio)
        isPiPAvailable = next.pipAvailable
        isPiPActive = next.pipActive

        attachEngineViewIfNeeded()
        next.load(request)
        next.play()
    }

    private func attachEngineViewIfNeeded() {
        guard let container = surfaceContainer, let engine else { return }
        let view = engine.view
        if view.superview === container { return }

        view.removeFromSuperview()
        // Use frame + autoresizing rather than NSLayoutConstraints here. The
        // player host is moved between SwiftUI-hosted containers (browse view
        // vs. player-only fullscreen); adding/removing constraints during those
        // transitions can throw from AppKit's display-cycle constraint update.
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        view.needsLayout = true
    }

    private func handleEngineFailure(_ message: String) {
        guard let request = currentRequest else {
            state = .failed(message)
            errorMessage = message
            return
        }

        #if canImport(VLCKit)
        if engineKind == .avPlayer, !fallbackAttempted {
            fallbackAttempted = true
            fallbackNotice = "AVPlayer could not open this stream. Falling back to VLCKit."
            startEngine(kind: .vlcKit, request: request)
            return
        }
        #endif

        state = .failed(message)
        errorMessage = message
    }

    private func perform(command: PlayerKeyCommand) {
        switch command {
        case .nextChannel:
            onNextChannel?()
        case .previousChannel:
            onPreviousChannel?()
        case .playPause:
            togglePlayPause()
        case .mute:
            toggleMute()
        case .fullscreen:
            toggleFullscreen()
        case .pictureInPicture:
            togglePictureInPicture()
        case .seekForward:
            seek(by: 10)
        case .seekBackward:
            seek(by: -10)
        }
    }
}

// MARK: - Engine delegate

extension PlayerCoordinator: PlaybackEngineDelegate {
    func engine(_ engine: PlaybackEngine, didChangeState state: PlaybackState) {
        guard engine === self.engine else { return }
        self.state = state
        if case .failed(let message) = state {
            errorMessage = message
        }
    }

    func engine(_ engine: PlaybackEngine, didUpdateTime time: Double, duration: Double) {
        guard engine === self.engine else { return }
        currentTime = time
        self.duration = duration
    }

    func engine(_ engine: PlaybackEngine, didChangePiP active: Bool, available: Bool) {
        guard engine === self.engine else { return }
        isPiPActive = active
        isPiPAvailable = available
    }

    func engine(_ engine: PlaybackEngine, didFail error: String) {
        guard engine === self.engine else { return }
        handleEngineFailure(error)
    }
}

// MARK: - Heuristics

enum PlaybackHeuristics {
    static func prefersVLCKit(for url: URL) -> Bool {
        let extensionName = url.pathExtension.lowercased()
        let directExtensions: Set<String> = ["ts", "mpegts", "m2ts", "mpg", "mpeg", "mkv", "avi"]
        if directExtensions.contains(extensionName) {
            return true
        }
        let lower = url.absoluteString.lowercased()
        return lower.contains("mpegts") || lower.contains("/live/") && lower.contains(".ts")
    }
}
