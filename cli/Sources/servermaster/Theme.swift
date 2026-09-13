//
//  Theme.swift
//  servermaster
//
//  The colour the terminal screen is drawn in.
//
//  It comes from the same setting the application uses for its background, so a
//  colour chosen in the window carries over to the terminal. One choice, both
//  shapes — rather than two places that drift.
//
//  Terminals disagree about colour. The 24-bit escape is what modern ones
//  understand and what gives an exact hue; older ones and anything reached over
//  a plain serial link do not, so there is a fall-back to the 256-colour cube,
//  and beneath that the plain eight colours that have worked since 1979.
//

import Foundation

nonisolated enum Theme {

    /// The hue in use, 0…1 around the colour wheel.
    static var hue: Double = AppSettings.load().backgroundHue

    /// Whether the terminal was seen to understand 24-bit colour.
    ///
    /// Asked of the environment rather than assumed: COLORTERM is what terminals
    /// that support it set, and guessing wrong paints the screen with literal
    /// escape sequences rather than colour.
    static var trueColour: Bool = {
        let value = ProcessInfo.processInfo.environment["COLORTERM"] ?? ""
        return value == "truecolor" || value == "24bit"
    }()

    /// The accent, as an escape sequence.
    static func accent(brightness: Double = 0.75, saturation: Double = 0.65) -> String {
        let (r, g, b) = rgb(hue: hue, saturation: saturation, brightness: brightness)
        if trueColour {
            return "\u{1B}[38;2;\(r);\(g);\(b)m"
        }
        // The 6×6×6 cube of the 256-colour palette: 16 + 36r + 6g + b.
        let index = 16 + 36 * (r * 5 / 255) + 6 * (g * 5 / 255) + (b * 5 / 255)
        return "\u{1B}[38;5;\(index)m"
    }

    static func paint(_ text: String, brightness: Double = 0.75) -> String {
        guard Style.enabled else { return text }
        return accent(brightness: brightness) + text + "\u{1B}[0m"
    }

    /// The same colour as a background, for a selected row.
    static func highlight(_ text: String) -> String {
        guard Style.enabled else { return text }
        let (r, g, b) = rgb(hue: hue, saturation: 0.55, brightness: 0.42)
        if trueColour {
            return "\u{1B}[48;2;\(r);\(g);\(b)m\u{1B}[97m\(text)\u{1B}[0m"
        }
        return Style.inverse(text)
    }

    /// HSB to RGB, the standard sextant walk.
    private static func rgb(hue: Double, saturation: Double, brightness: Double)
    -> (Int, Int, Int) {
        let h = (hue.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1) * 6
        let sector = Int(h)
        let f = h - Double(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * f)
        let t = brightness * (1 - saturation * (1 - f))

        let (r, g, b): (Double, Double, Double)
        switch sector % 6 {
        case 0: (r, g, b) = (brightness, t, p)
        case 1: (r, g, b) = (q, brightness, p)
        case 2: (r, g, b) = (p, brightness, t)
        case 3: (r, g, b) = (p, q, brightness)
        case 4: (r, g, b) = (t, p, brightness)
        default: (r, g, b) = (brightness, p, q)
        }
        return (Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
