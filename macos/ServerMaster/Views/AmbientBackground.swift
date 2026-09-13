//
//  AmbientBackground.swift
//  ServerMaster
//
//  The moving colour behind the Control screen — the effect Apple Music puts
//  behind a playing album.
//
//  It is a mesh gradient: colours bleeding between control points that drift.
//  That is what the effect actually is, and no arrangement of blurred circles
//  quite reproduces it.
//
//  Two things decide whether it works, and the first attempt got both wrong.
//
//  The palette has to be genuinely varied. A mesh built from three near-identical
//  navy tones has nothing to blend and renders as flat colour — so the resting
//  palette here spans real hues, and when servers are running their accents are
//  expanded into a family of shades rather than repeated.
//
//  And the points have to move far enough to see. A tenth of the width looks
//  like nothing at this scale.
//
//  The colours come from what is running — one accent per server — so the screen
//  says the state of things before a word of it has been read.
//

import SwiftUI
import AppKit

struct AmbientBackground: View {

    /// One colour per running server; empty when nothing is running.
    var colours: [Color]
    var isActive: Bool
    /// The hue used when nothing is running, and how fast the mesh drifts —
    /// both come from settings so the background can be tuned or turned off.
    var hue: Double = Self.baseHue
    var speed: Double = 1
    /// 0 makes it black and white.
    var saturation: Double = 1

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = Self.palette(from: colours, scheme: scheme,
                                   restingHue: hue, colourfulness: saturation)

        ZStack {
            // Mesh gradients arrived in macOS 15 and the app still runs on 14,
            // so the older path gets soft blobs of the same palette. Raising the
            // deployment target for a background would be the wrong trade.
            if #available(macOS 15.0, *) {
                MeshBackground(colours: palette,
                               reduceMotion: reduceMotion || speed <= 0,
                               speed: speed)
            } else {
                BlobBackground(colours: palette,
                               reduceMotion: reduceMotion || speed <= 0)
            }
        }
        .opacity(isActive ? 1 : 0.9)
        .animation(.easeInOut(duration: 1.5), value: isActive)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Building a palette worth blending

    /// The colour the background is made of when nothing is running.
    ///
    /// One number, in one place. The whole effect is shades of this — change it
    /// and the app changes mood.
    static let baseHue: Double = 0.62        // deep blue

    /// Six shades of a single colour.
    ///
    /// Shades, not a spread of hues: a background that wanders across the colour
    /// wheel is a background that competes with everything in front of it. What
    /// makes a mesh out of one colour is the range of saturation and brightness,
    /// not the range of hue — so the hue is fixed and those two do the work.
    ///
    /// When servers are running the hue comes from the first one's accent, so the
    /// screen still changes colour with what is happening; it just stays one
    /// colour at a time.
    static func palette(from accents: [Color], scheme: ColorScheme,
                        restingHue: Double = baseHue,
                        colourfulness: Double = 1) -> [Color] {
        let hue = accents.compactMap { HSB($0)?.hue }.first ?? restingHue

        // Saturation climbs while brightness falls, which is what gives a single
        // hue depth. Both ends stay away from the extremes: a fully saturated
        // corner reads as a colour cast over the text rather than as background.
        let steps: [(saturation: Double, brightness: Double)] = scheme == .dark
            ? [(0.45, 0.52), (0.58, 0.44), (0.68, 0.37),
               (0.74, 0.30), (0.62, 0.40), (0.50, 0.48)]
            : [(0.16, 0.99), (0.24, 0.96), (0.32, 0.93),
               (0.40, 0.90), (0.28, 0.95), (0.20, 0.98)]

        // Colourfulness scales the saturation of every step at once. At zero the
        // whole thing is shades of grey, and the brightness steps — which is
        // where the depth comes from — still do their work.
        let amount = max(0, min(1, colourfulness))
        return steps.map {
            Color(hue: hue, saturation: $0.saturation * amount, brightness: $0.brightness)
        }
    }

    /// A colour taken apart, so the hue of a profile's accent can be read out.
    struct HSB {
        var hue: Double, saturation: Double, brightness: Double

        init?(_ colour: Color) {
            guard let ns = NSColor(colour).usingColorSpace(.sRGB) else { return nil }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            hue = Double(h); saturation = Double(s); brightness = Double(b)
        }

        var colour: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }
    }
}

// MARK: - The mesh

/// A four-by-four grid of coloured control points, with the inner ones drifting.
///
/// The edges stay pinned. A control point that wanders off the edge leaves a
/// corner the mesh does not cover, and `background` fills it with flat colour — a
/// visible hard patch in the corner of the window. So only the coordinates that
/// can move without opening a gap do: interior points move freely, points on an
/// edge slide along it, corners are nailed down.
@available(macOS 15.0, *)
private struct MeshBackground: View {

    let colours: [Color]
    let reduceMotion: Bool
    let speed: Double

    private static let side = 4

    /// When this view appeared, so the angle fed to sin() stays a small number.
    ///
    /// This is what made the animation stutter. `timeIntervalSinceReferenceDate`
    /// is around 8×10⁸; divided down it is still in the hundreds of millions, and
    /// a Double that large has so little resolution left that consecutive frames
    /// land on the same value and then jump. Counting from a start date keeps the
    /// argument in the tens, where every frame is a distinct position.
    @State private var start = Date()

    var body: some View {
        // No minimumInterval: the display link decides, which is what makes it
        // smooth. Asking for thirty a second on a 120 Hz screen guarantees that
        // frames land unevenly against the refresh.
        TimelineView(.animation) { timeline in
            // A full circuit in about twenty seconds. Slower and it stops
            // looking alive; faster and it pulls the eye off the content.
            let time = reduceMotion ? 0
                : timeline.date.timeIntervalSince(start) * max(0, speed) / 2.6

            MeshGradient(width: Self.side,
                         height: Self.side,
                         points: points(at: time),
                         colors: meshColours,
                         background: colours.first ?? .clear,
                         smoothsColors: true)
        }
    }

    private func points(at time: Double) -> [SIMD2<Float>] {
        let last = Self.side - 1
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(Self.side * Self.side)

        for row in 0..<Self.side {
            for column in 0..<Self.side {
                let baseX = Float(column) / Float(last)
                let baseY = Float(row) / Float(last)

                // Its own phase, so no two points swing together.
                let phase = Double(row * Self.side + column) * 1.7
                // Strictly less than half the spacing between points.
                //
                // At 0.20 the two interior columns, which sit at ⅓ and ⅔, could
                // reach 0.53 and 0.47 and cross over. A crossed pair folds the
                // quad inside out, and a folded quad draws as a hard-edged wedge
                // across the window — which is exactly what appeared. Half of ⅓
                // is 0.167, so 0.12 leaves room and still visibly moves.
                let amount: Float = 0.12
                let wobbleX = Float(sin(time + phase)) * amount
                let wobbleY = Float(cos(time * 0.83 + phase * 1.4)) * amount

                let onSide = column == 0 || column == last
                let onTopOrBottom = row == 0 || row == last

                result.append(SIMD2(baseX + (onSide ? 0 : wobbleX),
                                    baseY + (onTopOrBottom ? 0 : wobbleY)))
            }
        }
        return result
    }

    /// One colour per point, walked with a stride coprime to the row length so
    /// the same colour never lands directly above itself and the grid does not
    /// come out in stripes.
    private var meshColours: [Color] {
        let count = Self.side * Self.side
        guard !colours.isEmpty else { return Array(repeating: .gray, count: count) }
        return (0..<count).map { colours[($0 * 5) % colours.count] }
    }
}

// MARK: - The older path

/// macOS 14: large soft blobs of the same palette. Not the same thing, but the
/// same idea, and it does not need a mesh.
private struct BlobBackground: View {

    let colours: [Color]
    let reduceMotion: Bool

    @State private var start = Date()

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            TimelineView(.animation(minimumInterval: reduceMotion ? nil : 1.0 / 10)) { timeline in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSince(start) / 20

                Canvas { context, canvas in
                    context.fill(Rectangle().path(in: CGRect(origin: .zero, size: canvas)),
                                 with: .color(colours.first ?? .gray))
                    for (index, colour) in colours.enumerated() {
                        let phase = Double(index) * 2.4
                        let x = 0.5 + 0.45 * sin(time * .pi * 2 + phase)
                        let y = 0.5 + 0.40 * cos(time * .pi * 2 * 0.73 + phase * 1.3)
                        let radius = min(canvas.width, canvas.height) * 0.7

                        let centre = CGPoint(x: x * canvas.width, y: y * canvas.height)
                        let rect = CGRect(x: centre.x - radius, y: centre.y - radius,
                                          width: radius * 2, height: radius * 2)
                        context.fill(Circle().path(in: rect),
                                     with: .radialGradient(
                                        Gradient(colors: [colour, colour.opacity(0)]),
                                        center: centre, startRadius: 0, endRadius: radius))
                    }
                }
                .blur(radius: min(size.width, size.height) * 0.10)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }
}

// MARK: - Reading a profile's accent

nonisolated extension Color {

    /// A colour written as “#RRGGBB”, or nil when it is not one.
    ///
    /// Separate from `init(hex:)`, which answers grey for anything it cannot
    /// read. Grey is right for a swatch in the editor and wrong here: a
    /// malformed accent would put a grey patch in the background and wash out
    /// the colours of the servers that are actually running.
    static func accent(fromHex hex: String) -> Color? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6,
              text.allSatisfy({ $0.isHexDigit }),
              let value = UInt32(text, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
