//
//  TVTheme.swift
//  StalkerDesk
//
//  Shared visual language for the couch-friendly interface. These tokens and
//  modifiers intentionally use only cross-platform SwiftUI APIs so the same
//  components can move to a tvOS target later (with focus effects added by the
//  tvOS focus engine).
//

import SwiftUI

enum TVTheme {
    static let accent = Color(red: 0.32, green: 0.82, blue: 0.89)
    static let accentDim = Color(red: 0.18, green: 0.48, blue: 0.56)
    static let background = LinearGradient(
        colors: [
            Color(red: 0.015, green: 0.02, blue: 0.035),
            Color(red: 0.025, green: 0.05, blue: 0.075),
            Color(red: 0.01, green: 0.012, blue: 0.02)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let surface = Color.white.opacity(0.055)
    static let surfaceElevated = Color.white.opacity(0.10)
    static let hairline = Color.white.opacity(0.10)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.40)
    static let cardRadius: CGFloat = 14
}

struct TVHoverScale: ViewModifier {
    var isEnabled: Bool = true
    var scale: CGFloat = 1.035
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && isEnabled ? scale : 1)
            .shadow(
                color: hovering && isEnabled ? .black.opacity(0.45) : .clear,
                radius: hovering && isEnabled ? 16 : 0,
                y: hovering && isEnabled ? 8 : 0
            )
            .animation(.easeOut(duration: 0.16), value: hovering)
            #if os(macOS)
            .onHover { hovering = $0 }
            #endif
    }
}

extension View {
    func tvHoverScale(_ enabled: Bool = true) -> some View {
        modifier(TVHoverScale(isEnabled: enabled))
    }
}

struct TVCategoryPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.82))
                .padding(.horizontal, 17)
                .padding(.vertical, 9)
                .background(
                    isSelected ? TVTheme.accent : TVTheme.surface,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isSelected ? Color.clear : TVTheme.hairline,
                            lineWidth: 1
                        )
                }
        }
        .buttonStyle(.plain)
        .tvHoverScale(false)
    }
}

struct TVEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(TVTheme.accent.opacity(0.85))
            Text(title)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(TVTheme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(TVTheme.accent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}
