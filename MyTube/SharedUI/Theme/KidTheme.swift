//
//  KidTheme.swift
//  MyTube
//
//  Cosmetic design system for a warm, kid-friendly look & feel.
//

import SwiftUI

struct KidPalette {
    let accent: Color
    let accentSecondary: Color
    let bgTop: Color
    let bgBottom: Color
    let cardFill: Color
    let cardStroke: Color
    let chipFill: Color
    let success: Color
    let warning: Color
    let error: Color

    var backgroundGradient: LinearGradient {
        LinearGradient(colors: [bgTop, bgBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension ThemeDescriptor {
    var kidPalette: KidPalette {
        switch self {
        case .ocean:
            return KidPalette(
                accent: Color(red: 0.13, green: 0.66, blue: 0.98),
                accentSecondary: Color(red: 0.35, green: 0.89, blue: 0.98),
                bgTop: Color(red: 0.93, green: 0.92, blue: 1.00),
                bgBottom: Color(red: 0.87, green: 0.90, blue: 1.00),
                cardFill: Color.white.opacity(0.6),
                cardStroke: Color(red: 0.13, green: 0.66, blue: 0.98).opacity(0.25),
                chipFill: Color.white.opacity(0.75),
                success: Color(red: 0.18, green: 0.73, blue: 0.43),
                warning: Color(red: 1.00, green: 0.62, blue: 0.00),
                error: Color(red: 0.95, green: 0.33, blue: 0.36)
            )
        case .sunset:
            return KidPalette(
                accent: Color(red: 0.97, green: 0.35, blue: 0.54),
                accentSecondary: Color(red: 1.00, green: 0.68, blue: 0.37),
                bgTop: Color(red: 1.00, green: 0.90, blue: 0.80),
                bgBottom: Color(red: 1.00, green: 0.78, blue: 0.72),
                cardFill: Color.white.opacity(0.6),
                cardStroke: Color(red: 0.97, green: 0.35, blue: 0.54).opacity(0.25),
                chipFill: Color.white.opacity(0.75),
                success: Color(red: 0.18, green: 0.73, blue: 0.43),
                warning: Color(red: 1.00, green: 0.62, blue: 0.00),
                error: Color(red: 0.95, green: 0.33, blue: 0.36)
            )
        case .forest:
            return KidPalette(
                accent: Color(red: 0.25, green: 0.70, blue: 0.49),
                accentSecondary: Color(red: 0.52, green: 0.88, blue: 0.52),
                bgTop: Color(red: 0.88, green: 0.98, blue: 0.90),
                bgBottom: Color(red: 0.80, green: 0.94, blue: 0.86),
                cardFill: Color.white.opacity(0.6),
                cardStroke: Color(red: 0.25, green: 0.70, blue: 0.49).opacity(0.25),
                chipFill: Color.white.opacity(0.75),
                success: Color(red: 0.18, green: 0.73, blue: 0.43),
                warning: Color(red: 1.00, green: 0.62, blue: 0.00),
                error: Color(red: 0.95, green: 0.33, blue: 0.36)
            )
        case .galaxy:
            return KidPalette(
                accent: Color(red: 0.52, green: 0.46, blue: 0.98),
                accentSecondary: Color(red: 0.36, green: 0.79, blue: 0.98),
                bgTop: Color(red: 0.93, green: 0.92, blue: 1.00),
                bgBottom: Color(red: 0.87, green: 0.90, blue: 1.00),
                cardFill: Color.white.opacity(0.6),
                cardStroke: Color(red: 0.52, green: 0.46, blue: 0.98).opacity(0.25),
                chipFill: Color.white.opacity(0.75),
                success: Color(red: 0.18, green: 0.73, blue: 0.43),
                warning: Color(red: 1.00, green: 0.62, blue: 0.00),
                error: Color(red: 0.95, green: 0.33, blue: 0.36)
            )
        }
    }
}

struct KidAppBackground: View {
    @EnvironmentObject private var appEnvironment: AppEnvironment

    var body: some View {
        appEnvironment.activeProfile.theme.kidPalette.backgroundGradient
            .ignoresSafeArea()
    }
}

struct KidCardBackground: ViewModifier {
    @EnvironmentObject private var appEnvironment: AppEnvironment

    func body(content: Content) -> some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        return content
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(palette.cardStroke, lineWidth: 1)
            )
            .shadow(color: palette.accent.opacity(0.08), radius: 10, y: 6)
    }
}

extension View {
    func kidCardBackground() -> some View {
        modifier(KidCardBackground())
    }
}

struct KidPrimaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var appEnvironment: AppEnvironment

    func makeBody(configuration: Configuration) -> some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        return configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(colors: [palette.accent, palette.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            )
            .shadow(color: palette.accent.opacity(0.25), radius: 10, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isPressed)
    }
}

struct KidSecondaryButtonStyle: ButtonStyle {
    @EnvironmentObject private var appEnvironment: AppEnvironment

    func makeBody(configuration: Configuration) -> some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        return configuration.label
            .font(.system(.headline, design: .rounded))
            .foregroundStyle(palette.accent)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(palette.cardStroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

struct KidCircleIconButtonStyle: ButtonStyle {
    @EnvironmentObject private var appEnvironment: AppEnvironment

    func makeBody(configuration: Configuration) -> some View {
        let palette = appEnvironment.activeProfile.theme.kidPalette
        return configuration.label
            .frame(width: 56, height: 56)
            .background(
                Circle().fill(
                    LinearGradient(colors: [palette.accent, palette.accentSecondary], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .foregroundStyle(Color.white)
            .shadow(color: palette.accent.opacity(0.25), radius: 8, y: 5)
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}


