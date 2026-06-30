// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.

import SwiftUI

// MARK: - Card surface

private struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(Palette.cardSurface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Palette.cardBorder, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
    }
}

extension View {
    func cardBackground(cornerRadius: CGFloat = 16) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

/// A vertical stack of rows on a single card surface. Callers interleave
/// `RowDivider` between rows.
struct GroupedCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .cardBackground(cornerRadius: cornerRadius)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.separator)
            .frame(height: 1)
    }
}

// MARK: - Section header

/// Uppercase monospaced section label, e.g. "PRIORITY ORDER".
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.appMono(11, .medium))
            .foregroundColor(Palette.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.bottom, 9)
    }
}

// MARK: - Status indicators

/// A filled dot with an expanding, fading "ping" ring — the carrying/connected state.
struct PulseDot: View {
    var color: Color
    var size: CGFloat = 9
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .scaleEffect(animate ? 2.4 : 0.85)
                .opacity(animate ? 0 : 0.55)
            Circle()
                .fill(color)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }
}

/// A solid dot, no animation.
struct SolidDot: View {
    var color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// A hollow ring dot (standby / probe-healthy members).
struct RingDot: View {
    var color: Color
    var size: CGFloat = 11

    var body: some View {
        Circle()
            .fill(Palette.cardSurface)
            .overlay(Circle().strokeBorder(color, lineWidth: 2))
            .frame(width: size, height: size)
    }
}

// MARK: - Badge

/// Small monospaced pill, e.g. ARMED / HOT SPARE / ON / MANUAL / PAUSED.
struct Badge: View {
    let text: String
    var color: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.appMono(9, .semibold))
            .foregroundColor(filled ? .white : color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(filled ? color : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(filled ? Color.clear : color.opacity(0.4), lineWidth: 1)
            )
    }
}

// MARK: - Throughput

/// A labelled directional throughput readout, e.g. "DOWNLOAD  ↓ 1.24 MB/s".
struct ThroughputStat: View {
    let label: String
    let arrow: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.appMono(10))
                .foregroundColor(Palette.secondaryText)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(arrow) \(value)")
                    .font(.appMono(16, .medium))
                    .foregroundColor(Palette.primaryText)
                Text(unit)
                    .font(.appMono(11))
                    .foregroundColor(Palette.mutedText)
            }
        }
    }
}

// MARK: - Key/value rows

/// A label on the left and a (usually monospaced) value on the right, with an
/// optional "copy" affordance — the building block of the interface/peer tables.
struct KeyValueRow: View {
    let key: String
    let value: String
    var monoValue: Bool = true
    var valueColor: Color = Palette.primaryText
    var copyAccent: Color? = nil
    var onCopy: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.appSans(14))
                .foregroundColor(Palette.secondaryText)
            Spacer(minLength: 12)
            Text(value)
                .font(monoValue ? .appMono(12) : .appSans(14))
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
            if let copyAccent = copyAccent {
                Text("copy")
                    .font(.appMono(11))
                    .foregroundColor(copyAccent)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { onCopy?() }
    }
}

/// A toggle row with a title and optional subtitle.
struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var accent: Color

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.appSans(15))
                    .foregroundColor(Palette.primaryText)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.appSans(11))
                        .foregroundColor(Palette.mutedText)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(accent)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }
}

/// A tappable disclosure row showing a trailing value and chevron, e.g.
/// "Theme            System ›".
struct DisclosureRow: View {
    let title: String
    var value: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(.appSans(15))
                    .foregroundColor(Palette.primaryText)
                Spacer(minLength: 12)
                if let value = value {
                    Text(value)
                        .font(.appSans(14))
                        .foregroundColor(Palette.secondaryText)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.faintText)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sensitivity segmented control

/// Custom segmented control matching the redesign: an accent-filled selected
/// segment with white text on a tinted track.
struct SensitivityPicker: View {
    @Binding var selection: FailoverSensitivity
    var accent: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FailoverSensitivity.allCases) { option in
                Text(option.displayName)
                    .font(.appSans(12, selection == option ? .semibold : .regular))
                    .foregroundColor(selection == option ? .white : Palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selection == option ? accent : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) { selection = option }
                    }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Palette.segmentTrack)
        )
    }
}
