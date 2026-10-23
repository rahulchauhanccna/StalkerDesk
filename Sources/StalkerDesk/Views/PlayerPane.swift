//
//  PlayerPane.swift
//  StalkerDesk
//
//  Video stage, transport controls and live EPG for the selected channel.
//

import StalkerDeskCore
import SwiftUI

struct PlayerPane: View {
    @ObservedObject var player: PlayerCoordinator
    @EnvironmentObject private var appState: AppState
    let channel: StalkerChannel
    var isSurfaceActive: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            videoStage
            controlBar
            Divider()
            EPGDetailView(channel: channel)
                .environmentObject(appState)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Video

    private var videoStage: some View {
        ZStack {
            Color.black

            PlayerSurface(player: player, isActive: isSurfaceActive)

            if appState.isResolvingStream || player.state == .preparing {
                LoadingOverlay(
                    title: "Resolving stream",
                    subtitle: "Resolving \(channel.name)"
                )
            } else if player.state == .buffering {
                LoadingOverlay(title: "Buffering", subtitle: "Waiting for media")
            }

            if case .failed(let message) = player.state {
                PlaybackErrorOverlay(
                    message: message,
                    retry: { appState.retryPlayback() }
                )
            }

            VStack(spacing: 0) {
                topOverlay
                Spacer()
                HStack(alignment: .bottom) {
                    if let notice = player.fallbackNotice {
                        Label(notice, systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.62), in: Capsule())
                            .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .animation(.easeInOut(duration: 0.2), value: player.state)
    }

    private var topOverlay: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 9, weight: .black))
                        .tracking(0.7)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.65), in: Capsule())

                Text(channel.displayNumber.isEmpty ? channel.name : "\(channel.displayNumber)  \(channel.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let current = appState.currentProgram {
                Text(current.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Text(player.engineKind.rawValue)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.72), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack(spacing: 13) {
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: playPauseSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Play / Pause (Space)")
            .disabled(!player.state.isActive && player.state != .paused)

            Button {
                player.toggleMute()
            } label: {
                Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 14))
                    .frame(width: 23)
            }
            .buttonStyle(.plain)
            .help("Mute (M)")

            Slider(
                value: Binding(
                    get: { player.volume },
                    set: { player.setVolume($0) }
                ),
                in: 0...1
            )
            .frame(width: 82)
            .controlSize(.mini)

            if player.isLive {
                Text("LIVE")
                    .font(.system(size: 9, weight: .black))
                    .tracking(0.7)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(.red.opacity(0.7))
                    }
            } else {
                Text(formatTime(player.currentTime))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 1)
                )
                .controlSize(.mini)
                Text(formatTime(player.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Text(playbackStatusLabel)
                .font(.caption2)
                .foregroundStyle(statusColor)
                .lineLimit(1)

            Menu {
                ForEach(PlayerAspectRatio.allCases) { ratio in
                    Button {
                        player.setAspectRatio(ratio)
                    } label: {
                        if ratio == player.aspectRatio {
                            Label(ratio.displayName, systemImage: "checkmark")
                        } else {
                            Label(ratio.displayName, systemImage: ratio.symbolName)
                        }
                    }
                }
            } label: {
                Image(systemName: player.aspectRatio.symbolName)
                    .font(.system(size: 13))
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Aspect ratio")

            Button {
                player.togglePictureInPicture()
            } label: {
                Image(systemName: player.isPiPActive ? "pip.exit" : "pip.enter")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(!player.isPiPAvailable && !player.isPiPActive)
            .help("Picture in Picture (P)")

            Button {
                player.toggleFullscreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Fullscreen (F)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var playPauseSymbol: String {
        switch player.state {
        case .playing, .buffering: return "pause.fill"
        default: return "play.fill"
        }
    }

    private var playbackStatusLabel: String {
        if appState.isResolvingStream { return "Resolving…" }
        if player.state == .playing, let current = appState.currentProgram {
            return current.title
        }
        return player.state.displayName
    }

    private var statusColor: Color {
        switch player.state {
        case .failed: return .red
        case .playing: return .secondary
        default: return .secondary
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

// MARK: - Overlays

private struct LoadingOverlay: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .tint(.white)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PlaybackErrorOverlay: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("Stream unavailable")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(maxWidth: 380)
            Button("Try Again", action: retry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(22)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - EPG

private struct EPGDetailView: View {
    let channel: StalkerChannel
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    SectionTitle("Live Guide")
                    Spacer()
                    if appState.isLoadingEPG {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button {
                        appState.loadEPG(for: channel)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh guide")
                }

                if let current = appState.currentProgram {
                    CurrentProgramCard(program: current)
                } else if appState.isLoadingEPG {
                    GuideSkeleton()
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                        Text(appState.epgError ?? "No programme information is available from this portal.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                if !appState.upcomingPrograms.isEmpty {
                    Text("Up next")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    VStack(spacing: 1) {
                        ForEach(appState.upcomingPrograms) { program in
                            EPGProgramRow(program: program)
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4))
                    }
                }

                if let error = appState.epgError, appState.currentProgram != nil {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct CurrentProgramCard: View {
    let program: StalkerEPGProgram

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            let live = program.isLive(at: context.date)
            let progress = program.progress(at: context.date)

            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(program.timeRangeLabel)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if live {
                        Text("ON NOW")
                            .font(.system(size: 8, weight: .black))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.red, in: Capsule())
                    }
                    Spacer()
                    Text(formatRemaining(program: program, now: context.date))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(program.title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(2)

                if !program.description.isEmpty {
                    Text(program.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }

                ProgressView(value: progress)
                    .tint(live ? .red : .accentColor)
                    .controlSize(.small)

                HStack(spacing: 12) {
                    if let category = program.category {
                        Label(category, systemImage: "tag")
                    }
                    Text(program.start.formatted(date: .omitted, time: .shortened) + " – " + program.end.formatted(date: .omitted, time: .shortened))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(15)
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.12), Color(nsColor: .controlBackgroundColor)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Color.accentColor.opacity(0.18))
            }
        }
    }

    private func formatRemaining(program: StalkerEPGProgram, now: Date) -> String {
        let remaining = program.end.timeIntervalSince(now)
        guard remaining > 0 else { return "Finished" }
        let minutes = Int(remaining / 60)
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m left"
        }
        return "\(max(1, minutes))m left"
    }
}

private struct EPGProgramRow: View {
    let program: StalkerEPGProgram

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(program.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                Text(program.end.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 52, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(program.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if !program.description.isEmpty {
                    Text(program.description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if program.isArchive {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Catch-up may be available")
            }
            if program.hasRecording {
                Image(systemName: "record.circle")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.8))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.35))
    }
}

private struct GuideSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 12)
                .frame(maxWidth: 130)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.12))
                .frame(height: 20)
                .frame(maxWidth: 340)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.08))
                .frame(height: 12)
                .frame(maxWidth: 420)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
    }
}
