import CoachUI
import SwiftUI
import UIKit

// The gallery: every shot on this phone, full screen, newest first. Swipe pages between shots;
// a quiet filmstrip under them jumps anywhere (the current frame lit, the rest dimmed). Tap the
// photo to open it in the shot viewer (faders, Edit for Me, talk to edit). No labels.

struct Gallery: View {
    @Environment(AppModel.self) private var app
    @State private var selection: String?

    var body: some View {
        let shots = app.shots.shots
        ZStack {
            GXColor.void.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(shots) { shot in
                    GalleryPage(shot: shot)
                        .contentShape(Rectangle())
                        .onTapGesture { app.open(shot) }
                        .tag(Optional(shot.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // The gallery sits in an overlay of a view that ignores the safe area, so measure where
            // the keys actually are and push them below the Dynamic Island either way.
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                let screenHeight = ScreenInsets.window?.bounds.height ?? frame.maxY
                let top = 8 + max(0, ScreenInsets.top - frame.minY)
                let bottom = 14 + max(0, ScreenInsets.bottom - (screenHeight - frame.maxY))
                VStack(spacing: 0) {
                    HStack {
                        RoundKey(symbol: "xmark", label: "Close gallery") { app.showRoll = false }
                        Spacer()
                        RoundKey(symbol: "slider.horizontal.3", label: "Edit this shot") {
                            if let shot = current(shots) { app.open(shot) }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, top)
                    Spacer()
                    Filmstrip(shots: shots, selection: $selection)
                        .padding(.bottom, bottom)
                }
            }
        }
        .onAppear { if selection == nil { selection = shots.first?.id } }
        .onChange(of: shots.first?.id) { _, id in selection = id }
    }

    private func current(_ shots: [LocalShot]) -> LocalShot? {
        shots.first { $0.id == selection } ?? shots.first
    }
}

/// One shot, fitted, decoded off the main thread at screen size.
private struct GalleryPage: View {
    let shot: LocalShot
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 64)
        .padding(.bottom, 96)
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: shot.id) {
            let url = shot.jpegURL
            image = await Task.detached(priority: .userInitiated) { ShotStore.makeThumb(url: url, side: 2048) }.value
        }
    }
}

/// Small square frames under the photo; the current one full brightness and a touch larger.
private struct Filmstrip: View {
    @Environment(AppModel.self) private var app
    let shots: [LocalShot]
    @Binding var selection: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(shots) { shot in
                        let on = shot.id == selection
                        Button {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { selection = shot.id }
                        } label: {
                            ZStack {
                                GXColor.night
                                if let t = app.shots.thumbnail(shot, side: 160) {
                                    Image(decorative: t, scale: 1).resizable().scaledToFill()
                                }
                            }
                            .frame(width: on ? 44 : 36, height: on ? 56 : 48)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .opacity(on ? 1 : 0.42)
                        }
                        .buttonStyle(.plain)
                        .id(shot.id)
                    }
                }
                .frame(height: 56)
                .padding(.horizontal, 18)
            }
            .scrollIndicators(.hidden)
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: selection)
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { proxy.scrollTo(id, anchor: .center) }
            }
            .onAppear { if let id = selection { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

/// A 44 pt matte round key (close, edit).
struct RoundKey: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(GXColor.frost.opacity(0.8))
                .frame(width: 44, height: 44)
                .background(GXColor.frost.opacity(0.08), in: Circle())
        }
        .buttonStyle(KeyPressStyle())
        .accessibilityLabel(label)
    }
}
