import SwiftUI

/// The native layer of Night Drive. Over the real footage it's a windshield
/// head-up display; over the drawn cabin (used only if the footage is missing)
/// it fills in the car's two screens.
struct DriveOverlay: View {
    var compact = false

    var body: some View {
        if Bundle.main.url(forResource: "drive-rain", withExtension: "mp4") != nil {
            GeometryReader { geo in
                DriveHUD(compact: compact)
                    .frame(width: min(geo.size.width * (compact ? 0.9 : 0.62), compact ? 340 : 600))
                    .position(x: geo.size.width / 2, y: geo.size.height * (compact ? 0.5 : 0.6))
                    .allowsHitTesting(false)
            }
        } else {
            CabinScreensOverlay()
        }
    }
}

/// A windshield head-up display: luminous, slightly translucent figures that
/// look projected onto the glass. Speed follows the car in the footage.
private struct DriveHUD: View {
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            let ink = Color(red: 0.78, green: 0.97, blue: 1.0)
            content(ink: ink)
                .overlay(content(ink: ink).opacity(0.12).offset(y: compact ? 1.5 : 3).blur(radius: 1))   // the faint double image of a real HUD
                .shadow(color: Color(red: 0.3, green: 0.9, blue: 1.0).opacity(0.55), radius: compact ? 4 : 8)
                .rotation3DEffect(.degrees(12), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                // keeps the figures readable over bright neon
                .background(
                    Ellipse().fill(Color.black.opacity(0.32)).blur(radius: compact ? 14 : 28)
                        .padding(compact ? -10 : -24)
                )
        }
    }

    private func content(ink: Color) -> some View {
        let player = model.player
        let footage = FootagePlayer.shared
        let speed = Int(footage.speed().rounded())
        let scale: CGFloat = compact ? 0.55 : 1
        return HStack(alignment: .center, spacing: 34 * scale) {
            // speed limit sign
            ZStack {
                Circle().strokeBorder(Color(red: 1, green: 0.32, blue: 0.3), lineWidth: 5 * scale)
                Text("\(footage.speedLimit())")
                    .font(.system(size: 19 * scale, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(ink)
            }
            .frame(width: 46 * scale, height: 46 * scale)

            VStack(spacing: -4 * scale) {
                Text("\(speed)")
                    .font(.system(size: 66 * scale, weight: .medium, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("km/h")
                    .font(.system(size: 14 * scale, weight: .semibold, design: .rounded))
                    .tracking(1.5)
                    .opacity(0.8)
            }
            .foregroundStyle(ink)
            .frame(minWidth: 96 * scale)

            if !compact {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        HUDEqualizer(color: ink)
                            .frame(width: 22, height: 14)
                        Text(player.title.isEmpty ? "Encore" : player.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                    }
                    Text(player.author.isEmpty ? "Now playing" : player.author)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .opacity(0.75)
                        .lineLimit(1)
                }
                .foregroundStyle(ink)
                .frame(maxWidth: 230, alignment: .leading)
            }
        }
    }
}

/// Five bars dancing with the music, HUD style.
private struct HUDEqualizer: View {
    let color: Color
    @Environment(AppModel.self) private var model

    var body: some View {
        let bands = model.visualizer.bands
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let v = bands.isEmpty ? 0.3 : CGFloat(bands[min(bands.count - 1, i * max(1, bands.count / 6))])
                Capsule().fill(color).frame(width: 2.6, height: max(2, 14 * min(1, v * 1.2)))
            }
        }
    }
}

/// The drawn cabin's two screens (fallback when the footage isn't bundled).
private struct CabinScreensOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // Must match `driveFragment`: screens centred at y = -0.115 with half size
            // (0.19, 0.066), cluster at x = clX and infotainment at clX - 0.405, in
            // units of the height from the centre (y up).
            let clX = min(0.42, 0.5 * w / h - 0.24)
            let infoX = clX - 0.405
            let info = CGRect(x: w / 2 + (infoX - 0.19) * h, y: h / 2 + (0.115 - 0.066) * h, width: 0.38 * h, height: 0.132 * h)
            let cluster = CGRect(x: w / 2 + (clX - 0.19) * h, y: h / 2 + (0.115 - 0.066) * h, width: 0.38 * h, height: 0.132 * h)
            ZStack {
                InfotainmentText()
                    .frame(width: info.width * 0.92, height: info.height * 0.46)
                    .position(x: info.midX, y: info.minY + info.height * 0.27)
                ClusterSpeed()
                    .frame(width: cluster.height * 0.9, height: cluster.height * 0.8)
                    .position(x: cluster.midX, y: cluster.midY + cluster.height * 0.02)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Song, artist and elapsed time, with the artwork, on the infotainment screen.
private struct InfotainmentText: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let glow = Color(red: 0.6, green: 0.9, blue: 1.0)
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            GeometryReader { g in
                let size = g.size.height
                HStack(spacing: size * 0.22) {
                    Group {
                        if let art = player.artwork {
                            Color.clear.overlay(Image(nsImage: art).resizable().aspectRatio(contentMode: .fill))
                        } else {
                            LinearGradient(colors: player.palette.gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    }
                    .frame(width: size * 0.92, height: size * 0.92)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
                    VStack(alignment: .leading, spacing: size * 0.04) {
                        Text(player.title.isEmpty ? "Encore" : player.title)
                            .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(player.author.isEmpty ? "Now playing" : player.author)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(formatTime(player.position(at: timeline.date)))
                                .monospacedDigit()
                        }
                        .font(.system(size: size * 0.25, weight: .medium, design: .rounded))
                        .foregroundStyle(glow.opacity(0.8))
                    }
                }
                .shadow(color: glow.opacity(0.45), radius: 3)
            }
        }
    }
}

/// The speed readout between the cluster's two gauges. The car cruises at a
/// gentle, slowly varying speed that matches the scene's motion.
private struct ClusterSpeed: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            GeometryReader { g in
                let size = g.size.height
                let t = timeline.date.timeIntervalSinceReferenceDate
                let speed = Int((47 + 4 * sin(t * 0.05) + 1.5 * sin(t * 0.23)).rounded())
                VStack(spacing: 0) {
                    Text("\(speed)")
                        .font(.system(size: size * 0.42, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("km/h")
                        .font(.system(size: size * 0.14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.6, green: 0.85, blue: 1.0).opacity(0.8))
                    HStack(spacing: size * 0.06) {
                        Text("D").foregroundStyle(.white)
                        Text("ECO").foregroundStyle(Color.green.opacity(0.85))
                    }
                    .font(.system(size: size * 0.12, weight: .bold, design: .rounded))
                    .padding(.top, size * 0.04)
                }
                .frame(width: g.size.width, height: g.size.height)
                .shadow(color: Color(red: 0.4, green: 0.8, blue: 1.0).opacity(0.5), radius: 3)
            }
        }
    }
}
