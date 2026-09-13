//
//  GlassControls.swift
//  ServerMaster
//
//  Text fields and pickers that match the rest of the interface.
//
//  A bordered text field or a bezelled popup sitting next to a row of Liquid
//  Glass is the one control that still looks like a settings dialog from an
//  older system — and once the buttons are glass, those two are all that give it
//  away. These wrap the plain versions in the same material.
//
//  Deliberately not a global appearance override. The panels inside sheets keep
//  the system look, because a sheet is a dialog and is supposed to look like
//  one; this is for the surfaces that sit on the moving background.
//

import SwiftUI

extension View {

    /// A text field on glass. Apply to the field itself, after `.textFieldStyle(.plain)`.
    func glassField(width: CGFloat? = nil) -> some View {
        modifier(GlassFieldStyle(width: width))
    }

    /// A popup on glass.
    func glassPicker(width: CGFloat? = nil) -> some View {
        modifier(GlassPickerStyle(width: width))
    }
}

private struct GlassFieldStyle: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        let field = content
            .textFieldStyle(.plain)
            .frame(width: width)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

        if #available(macOS 26.0, *) {
            field.glassEffect(.regular, in: .capsule)
        } else {
            field
                .background(.quaternary.opacity(0.4), in: Capsule())
                .overlay(Capsule().stroke(.quaternary))
        }
    }
}

private struct GlassPickerStyle: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        // `.menu` rather than the default: a bezelled popup draws its own
        // chrome, and glass behind that is two backgrounds stacked. The menu
        // style is just the label and a chevron, which is what can sit on glass.
        let picker = content
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: width)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

        if #available(macOS 26.0, *) {
            picker.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            picker.background(.quaternary.opacity(0.4), in: Capsule())
        }
    }
}
