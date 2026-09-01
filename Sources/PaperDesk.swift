import AppKit
import CoreText
import SwiftUI

/// Paper Desk tokens — keep in sync with Android `PaperDesk.kt` / Windows `paper-desk.css`.
enum PaperDesk {
    static let deskLight = Color(red: 0.953, green: 0.933, blue: 0.894)      // #F3EEE4
    static let deskElevatedLight = Color(red: 0.980, green: 0.969, blue: 0.945) // #FAF7F1
    static let inkPrimaryLight = Color(red: 0.165, green: 0.141, blue: 0.094) // #2A2418
    static let inkSecondaryLight = Color(red: 0.420, green: 0.384, blue: 0.329) // #6B6254
    static let accentLight = Color(red: 0.639, green: 0.482, blue: 0.235)     // #A37B3C

    static let deskDark = Color(red: 0.102, green: 0.094, blue: 0.078)        // #1A1814
    static let deskElevatedDark = Color(red: 0.141, green: 0.125, blue: 0.094)
    static let inkPrimaryDark = Color(red: 0.941, green: 0.918, blue: 0.847)
    static let inkSecondaryDark = Color(red: 0.659, green: 0.624, blue: 0.557)
    static let accentDark = Color(red: 0.769, green: 0.604, blue: 0.361)

    static func desk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? deskDark : deskLight
    }

    static func elevated(for scheme: ColorScheme) -> Color {
        scheme == .dark ? deskElevatedDark : deskElevatedLight
    }

    static func ink(for scheme: ColorScheme) -> Color {
        scheme == .dark ? inkPrimaryDark : inkPrimaryLight
    }

    static func secondaryInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? inkSecondaryDark : inkSecondaryLight
    }

    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? accentDark : accentLight
    }

    /// Bundle fonts live in Resources/Fonts. Call once from AppDelegate.
    static func registerFonts() {
        let names = ["fraunces", "plus_jakarta_sans", "ibm_plex_mono"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static let uiFontName = "PlusJakartaSans"
    static let noteFontName = "Fraunces"
}

extension Font {
    /// Prefer bundled Paper Desk fonts; fall back to system if registration failed.
    static func deskUI(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: PaperDesk.uiFontName, size: size) != nil {
            return .custom(PaperDesk.uiFontName, size: size)
        }
        return .system(size: size, weight: weight)
    }

    static func deskNote(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if NSFont(name: PaperDesk.noteFontName, size: size) != nil {
            return .custom(PaperDesk.noteFontName, size: size)
        }
        return .system(size: size, weight: weight, design: .serif)
    }
}
