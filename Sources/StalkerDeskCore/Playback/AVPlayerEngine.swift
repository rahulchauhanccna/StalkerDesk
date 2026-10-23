//
//  AVPlayerEngine.swift
//  StalkerDeskCore
//
//  Primary playback engine. AVPlayerLayer is hosted in an AppKit view so it can
//  live inside SwiftUI and participate in PiP. HTTP headers are injected with
//  AVURLAssetHTTPHeaderFieldsKey, which is the de-facto supported mechanism for
//  AVFoundation HTTP playback.
//

import AppKit
import AVFoundation
import AVKit
import Foundation

@MainActor
final class AVPlayerEngine: NSObject, PlaybackEngine {
    let kind: PlaybackEngineKind = .avPlayer
    weak var delegate: PlaybackEngineDelegate?

    private let player = AVPlayer()
    private let surface = VideoSurfaceView()
    private var item: AVPlayerItem?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var pipController: AVPictureInPictureController?
    private var lastReportedState: PlaybackState = .idle

    var view: NSView { surface }

    var pipAvailable: Bool {
        pipController?.isPictureInPicturePossible ?? false
    }

    var pipActive: Bool {
        pipController?.isPictureInPictureActive ?? false
    }

    override init() {
        super.init()
        surface.playerLayer.player = player
        surface.onWindowChanged = { [weak self] in
            self?.preparePictureInPictureIfNeeded()
        }
        player.automaticallyWaitsToMinimizeStalling = true
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        itemStatusObservation?.invalidate()
        timeControlObservation?.invalidate()
        keepUpObservation?.invalidate()
        pipPossibleObservation?.invalidate()
    }

    // MARK: PlaybackEngine

    func load(_ request: PlaybackRequest) {
        teardownItemObservers()
        removeTimeObserver()
        lastReportedState = .preparing
        report(.preparing)

        var options: [String: Any] = [:]
        if !request.headers.isEmpty {
            // Undocumented but widely used and stable across macOS releases.
            options["AVURLAssetHTTPHeaderFieldsKey"] = request.headers
        }

        let asset = AVURLAsset(url: request.url, options: options)
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = request.isLive ? 5 : 2
        item = newItem
        player.replaceCurrentItem(with: newItem)

        if let startTime = request.startTime, startTime > 1 {
            player.seek(
                to: CMTime(seconds: startTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        observeItem(newItem)
        addPeriodicTimeObserver()
        addPlaybackNotifications(for: newItem)
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeTimeObserver()
        teardownItemObservers()
        if let pipController, pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        }
        item = nil
        lastReportedState = .idle
        report(.idle)
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setVolume(_ volume: Float) {
        player.volume = min(max(volume, 0), 1)
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func setAspectRatio(_ ratio: PlayerAspectRatio) {
        surface.aspectRatio = ratio
    }

    func togglePictureInPicture() {
        preparePictureInPictureIfNeeded()
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        }
    }

    // MARK: Observations

    private func observeItem(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handleItemStatus(status, error: error)
            }
        }

        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                self?.handleTimeControlStatus(status)
            }
        }

        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] item, _ in
            let keepingUp = item.isPlaybackLikelyToKeepUp
            Task { @MainActor [weak self] in
                guard let self, self.lastReportedState == .playing, !keepingUp else { return }
                self.report(.buffering)
            }
        }
    }

    private func teardownItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        keepUpObservation?.invalidate()
        keepUpObservation = nil
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
    }

    private func addPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds.isFinite ? time.seconds : 0
                let duration = self.item?.duration.seconds ?? 0
                self.delegate?.engine(
                    self,
                    didUpdateTime: max(0, seconds),
                    duration: duration.isFinite && duration > 0 ? duration : 0
                )
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func addPlaybackNotifications(for item: AVPlayerItem) {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.report(.ended)
            }
        })

        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.report(.buffering)
            }
        })
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, error: String?) {
        switch status {
        case .readyToPlay:
            if player.timeControlStatus == .playing {
                report(.playing)
            }
        case .failed:
            let message = error ?? "AVPlayer could not open this stream."
            lastReportedState = .failed(message)
            report(.failed(message))
            delegate?.engine(self, didFail: message)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            report(.playing)
        case .waitingToPlayAtSpecifiedRate:
            if case .failed = lastReportedState { return }
            report(.buffering)
        case .paused:
            if lastReportedState == .playing || lastReportedState == .buffering {
                report(.paused)
            }
        @unknown default:
            break
        }
    }

    // MARK: PiP

    private func preparePictureInPictureIfNeeded() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            delegate?.engine(self, didChangePiP: false, available: false)
            return
        }
        guard pipController == nil, surface.window != nil else { return }
        guard let controller = AVPictureInPictureController(playerLayer: surface.playerLayer) else {
            delegate?.engine(self, didChangePiP: false, available: false)
            return
        }

        controller.delegate = self
        pipController = controller

        pipPossibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let available = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.engine(self, didChangePiP: self.pipActive, available: available)
            }
        }
    }

    // MARK: State

    private func report(_ state: PlaybackState) {
        guard state != lastReportedState else { return }
        lastReportedState = state
        delegate?.engine(self, didChangeState: state)
    }
}

// MARK: - PiP delegate

extension AVPlayerEngine: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didChangePiP: true, available: true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didChangePiP: false, available: self.pipAvailable)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.engine(self, didChangePiP: false, available: self.pipAvailable)
        }
    }
}

// MARK: - Layer host

final class VideoSurfaceView: NSView {
    let playerLayer = AVPlayerLayer()
    var aspectRatio: PlayerAspectRatio = .fit {
        didSet { needsLayout = true }
    }
    var onWindowChanged: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch aspectRatio {
        case .sixteenNine:
            let targetAspect = 16.0 / 9.0
            var rect = bounds
            if bounds.width / max(bounds.height, 1) > targetAspect {
                rect.size.width = bounds.height * targetAspect
            } else {
                rect.size.height = bounds.width / targetAspect
            }
            rect.origin = CGPoint(
                x: bounds.midX - rect.width / 2,
                y: bounds.midY - rect.height / 2
            )
            playerLayer.frame = rect
            playerLayer.videoGravity = .resizeAspect
        case .fit:
            playerLayer.frame = bounds
            playerLayer.videoGravity = .resizeAspect
        case .zoom:
            playerLayer.frame = bounds
            playerLayer.videoGravity = .resizeAspectFill
        }

        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChanged?()
    }
}
