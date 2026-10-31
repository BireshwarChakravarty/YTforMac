import SwiftUI

/// The native layer of Night Drive: what's on the car's two screens. The
/// infotainment screen shows the song (the LED bars under it are drawn by the
/// Metal scene) and the digital cluster shows the speed between its gauges.
struct DriveOverlay: View {
    var compact = false

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
