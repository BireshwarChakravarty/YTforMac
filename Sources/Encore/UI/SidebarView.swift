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
                ForEach(Destination.browse) { d in SidebarRow(destination: d).tag(d) }
            }
            Section("Library") {
                ForEach(Destination.library) { d in SidebarRow(destination: d).tag(d) }
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
        let name = browser.accountName
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                if browser.isSignedIn {
                    Text(name.isEmpty ? "Signed in" : name)
                        .font(Theme.Fonts.title(13))
                        .lineLimit(1)
                    Text(browser.accountHandle.isEmpty ? "YouTube" : browser.accountHandle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                } else {
                    Text("Sign in to YouTube").font(Theme.Fonts.title(13))
                    Text("For your feed and subscriptions")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if browser.isSignedIn {
                    Button("Open My Channel") {
                        if !browser.accountHandle.isEmpty, let url = URL(string: "https://www.youtube.com/\(browser.accountHandle)") {
                            model.browse(url)
                        }
                    }
                    .disabled(browser.accountHandle.isEmpty)
                    Button("Switch Account…") {
                        if let url = URL(string: "https://www.youtube.com/channel_switcher") { model.browse(url) }
                    }
                    Divider()
                    Button("Sign Out of YouTube", role: .destructive) { browser.signOut() }
                } else {
                    Button("Sign In…") { model.destination = .home; browser.signIn() }
                }
                Divider()
                Button("Settings…") { openSettings() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
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
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12)))
        } else {
            Image(systemName: model.browser.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(Theme.signature)
        }
    }
}

private struct SidebarRow: View {
    let destination: Destination
    var body: some View {
        Label {
            Text(destination.title).font(Theme.Fonts.body(13))
        } icon: {
            Image(systemName: destination.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Theme.Palette.coral, Theme.Palette.magenta],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}
