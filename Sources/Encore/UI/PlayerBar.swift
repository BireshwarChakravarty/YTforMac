import SwiftUI

/// The persistent playback bar shown under the browser and the video.
struct PlayerBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 16) {
            Button { model.select(.nowPlaying) } label: {
                HStack(spacing: 11) {
                    ArtworkView(image: player.artwork, cornerRadius: 8)
                        .frame(width: 76, height: 43)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.title.isEmpty ? "Loading…" : player.title)
                            .font(Theme.Fonts.title(13.5))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if player.isAd {
                                Text("AD").font(.system(size: 9, weight: .black, design: .rounded))
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Capsule().fill(.yellow)).foregroundStyle(.black)
                            }
                            Text(player.author)
                                .font(Theme.Fonts.body(12))
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Now Playing")
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 2) {
                TransportControls(size: .small)
                ScrubberView(compact: true)
            }
            .frame(width: 380)

            HStack(spacing: 12) {
                MiniSpectrumView(bars: 22)
                    .frame(width: 96, height: 26)
                    .onTapGesture { model.setMode(.audio); model.select(.nowPlaying) }
                    .help("Open the visualiser")
                VolumeControl(width: 80)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .frame(height: 64)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Theme.Palette.stroke).frame(height: 1) }
    }
}
