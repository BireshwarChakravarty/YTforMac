import SwiftUI

/// The native layer of Night Drive: the song shown on the car's dashboard
/// screen. Everything else (windshield, rain, city lights, interior and the
/// screen's LED bars) is rendered by the Metal scene underneath.
struct DriveOverlay: View {
    var compact = false
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // Must match the screen rectangle in `driveFragment` (centre (0, -0.17), half size (0.19, 0.08), in units of the height).
            let screen = CGRect(x: w / 2 - 0.19 * h, y: h / 2 + 0.09 * h, width: 0.38 * h, height: 0.16 * h)
            DashboardScreenText()
                .frame(width: screen.width * 0.92, height: screen.height * 0.46, alignment: .topLeading)
                .position(x: screen.midX, y: screen.minY + screen.height * 0.27)
                .allowsHitTesting(false)
        }
    }
}

/// The infotainment readout: song, artist and elapsed time in a glowing display font.
private struct DashboardScreenText: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let glow = Color(red: 0.55, green: 0.95, blue: 1.0)
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            GeometryReader { g in
                let size = g.size.height
                VStack(alignment: .leading, spacing: size * 0.04) {
                    HStack(spacing: 6) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("FM 101.7").fontWeight(.semibold)
                        Spacer()
                        Text(formatTime(player.position(at: timeline.date)))
                    }
                    .font(.system(size: size * 0.2, weight: .medium, design: .monospaced))
                    .foregroundStyle(glow.opacity(0.75))
                    Text(player.title.isEmpty ? "Encore" : player.title)
                        .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(player.author.isEmpty ? "Now playing" : player.author)
                        .font(.system(size: size * 0.22, weight: .medium, design: .rounded))
                        .foregroundStyle(glow.opacity(0.8))
                        .lineLimit(1)
                }
                .shadow(color: glow.opacity(0.6), radius: 4)
            }
        }
    }
}
