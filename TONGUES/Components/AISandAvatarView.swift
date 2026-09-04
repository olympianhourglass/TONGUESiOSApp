import SwiftUI

/// The AI's speaking avatar: a field of soft white "sand" micro-particles
/// hovering over a blue disc, rendered by the `aiSandAvatar` Metal shader. The
/// particles idle-hover and ripple continuously, and react to the AI's live
/// speech loudness — louder makes them bounce and spread outward, quieter lets
/// them settle back into a gentle hover.
///
/// The speech level is read live from `SpeechClient.shared.playbackLevel` on
/// every animation tick, so the avatar reacts to whichever voice engine is
/// currently talking without any wiring at the call site.
///
/// Pairing: requires the `aiSandAvatar` function in `Shaders.metal`. Because
/// `ShaderLibrary` only resolves shaders the Metal compiler built at app-build
/// time, both files must ship together.
struct AISandAvatarView: View {
    /// Diameter of the circular avatar, in points.
    var size: CGFloat

    /// When false, the view renders a cheap, static grayed-out disc — no Metal
    /// pass and no speech-driven scaling. Used for AI messages that aren't the
    /// newest and aren't currently being read aloud.
    var active: Bool = true

    /// When set, overrides the live speech level — used by previews to freeze a
    /// loud/quiet frame. `nil` reads `SpeechClient.shared.playbackLevel`.
    var previewLevel: Float? = nil

    /// The chat's bedside manner, which tints the disc: Direct = blue (default),
    /// Warm = green, Withering = red.
    var tone: BedsideManner = .direct

    var body: some View {
        Group {
            if active {
                // The active avatar can afford the display's full rate — 60 Hz
                // reads noticeably smoother than a capped rate, and only one AI
                // avatar is ever active at a time.
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    // Time modded so float precision in the shader stays stable
                    // across long sessions (matches the liquid-glass wiper).
                    let t = Float(
                        timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 1000)
                    )
                    let level = previewLevel ?? SpeechClient.shared.playbackLevel
                    liquidDisc(time: t, level: level)
                        // The disc swells as the AI's voice gets louder.
                        .scaleEffect(1.0 + CGFloat(min(level, 1.0)) * 0.24)
                }
            } else {
                // Inactive: a flat grayed disc, no Metal and no animation.
                grayDisc
            }
        }
        .accessibilityHidden(true)
    }

    private func liquidDisc(time: Float, level: Float) -> some View {
        Rectangle()
            .colorEffect(
                ShaderLibrary.aiSandAvatar(
                    .float2(Float(size), Float(size)),
                    .float(time),
                    .float(level),
                    .float3(tone.discRim.x, tone.discRim.y, tone.discRim.z),
                    .float3(tone.discCore.x, tone.discCore.y, tone.discCore.z)
                )
            )
            .frame(width: size, height: size)
            .clipShape(Circle())
    }

    // Muted stand-in for dormant AI messages: a soft neutral gray disc with a
    // little radial depth so it still reads as an avatar, not a hole.
    private var grayDisc: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [Color(white: 0.86), Color(white: 0.70)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.6
                )
            )
            .frame(width: size, height: size)
    }
}

#Preview("Idle") {
    AISandAvatarView(size: 120, previewLevel: 0)
        .padding()
}

#Preview("Speaking (loud)") {
    AISandAvatarView(size: 120, previewLevel: 0.9)
        .padding()
}
