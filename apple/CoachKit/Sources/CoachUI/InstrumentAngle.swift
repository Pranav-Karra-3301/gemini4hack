import SwiftUI

/// The angle instrument glyphs (drum numerals, ruler value, key glyphs) turn by so they read
/// upright when the phone is held sideways. Layout containers never rotate.
private struct InstrumentGlyphAngleKey: EnvironmentKey {
    static let defaultValue: Angle = .zero
}

public extension EnvironmentValues {
    var instrumentGlyphAngle: Angle {
        get { self[InstrumentGlyphAngleKey.self] }
        set { self[InstrumentGlyphAngleKey.self] = newValue }
    }
}

public extension View {
    func instrumentGlyphAngle(_ a: Angle) -> some View {
        environment(\.instrumentGlyphAngle, a)
    }
}

/// Turns a glyph by the environment's `instrumentGlyphAngle`.
struct InstrumentGlyphTurn: ViewModifier {
    @Environment(\.instrumentGlyphAngle) private var angle

    func body(content: Content) -> some View {
        content
            .rotationEffect(angle)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: angle)
    }
}

extension View {
    func instrumentGlyphTurn() -> some View { modifier(InstrumentGlyphTurn()) }
}
