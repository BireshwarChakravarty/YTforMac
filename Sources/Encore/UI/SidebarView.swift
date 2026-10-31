import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<Destination?>(
            get: { model.destination },
            set: { if let d = $0 { model.select(d) } }
        )
        List(selection: selection) {
            NowPlayingRow()
                .tag(Destination.nowPlaying)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))

            Section("YouTube") {
                ForEach(Destination.browse) { d in
                    Label(d.title, systemImage: d.symbol).tag(d)
                }
            }
            Section("Library") {
                ForEach(Destination.library) { d in
                    Label(d.title, systemImage: d.symbol).tag(d)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 9) {
                EncoreMark().frame(width: 26, height: 26)
                Text("Encore").font(Theme.Fonts.display(19))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { AccountFooter() }
    }
}

/// The highlighted "Now Playing" entry with live artwork and a dancing glyph.
private struct NowPlayingRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 10) {
            if player.hasMedia, player.artwork != nil {
                ArtworkView(image: player.artwork, cornerRadius: 6, square: true)
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: Destination.nowPlaying.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.signature)
                    .frame(width: 30, height: 30)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Now Playing").font(Theme.Fonts.title(13))
                if player.hasMedia {
                    Text(player.title)
                        .font(Theme.Fonts.body(11))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if player.isPlaying { EqualizerGlyph(color: player.palette.primary) }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [player.palette.primary.opacity(0.22), player.palette.tertiary.opacity(0.18)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.07)))
                .opacity(player.hasMedia ? 1 : 0.5)
        )
    }
}

private struct AccountFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let browser = model.browser
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(browser.isSignedIn ? "Signed in" : "Not signed in")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(browser.isSignedIn ? "YouTube account" : "Sign in to YouTube")
                    .font(Theme.Fonts.title(12.5))
            }
            Spacer(minLength: 0)
            Menu {
                if browser.isSignedIn {
                    Button("Sign Out of YouTube", role: .destructive) { browser.signOut() }
                } else {
                    Button("Sign In…") { model.destination = .home; browser.signIn() }
                }
                Divider()
                Button("Settings…") { openSettings() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05)))
        .padding(10)
        .contentShape(Rectangle())
        .onTapGesture {
            if !browser.isSignedIn { model.destination = .home; browser.signIn() }
        }
    }

    @ViewBuilder private var avatar: some View {
        if let url = model.browser.avatarURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle().fill(Theme.signature)
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
        } else {
            Image(systemName: model.browser.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle.badge.plus")
                .font(.system(size: 26))
                .foregroundStyle(Theme.signature)
        }
    }
}
