//
//  TimerState.swift
//  Timer
//
//  Created by David on 26.07.24.
//

import Foundation
import SwiftUI
import AppKit

enum TimerState {
    case running
    case paused
    case stopped
    /// The countdown reached zero and is now counting overtime until the next phase is started.
    case finished
}

/// Anchor's colours: harbour blue for focus, sea green and indigo for breaks, coral when time is up.
/// The dark variants are lighter so they stand out on a dark window but still carry white text.
enum Palette {
    static let focus = dynamic(light: 0x23507A, dark: 0x3D8BDB)
    static let shortBreak = dynamic(light: 0x237A64, dark: 0x2FA383)
    static let longBreak = dynamic(light: 0x4A4CA8, dark: 0x7173E0)
    static let timesUp = dynamic(light: 0xD9472F, dark: 0xEF5F47)

    static var timesUpColor: Color {
        Color(nsColor: timesUp)
    }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum TimerPhase: CaseIterable {
    case focus
    case shortBreak
    case longBreak

    /// The choices offered in Settings for how many focus sessions come before a long break.
    static let sessionsPerLongBreakRange = 2...8

    /// A long break comes after every this many focus sessions, shown as the dots above the timer.
    static var focusSessionsPerLongBreak: Int {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "sessionsPerLongBreak") == nil
            ? 4
            : defaults.integer(forKey: "sessionsPerLongBreak")
        return min(sessionsPerLongBreakRange.upperBound, max(sessionsPerLongBreakRange.lowerBound, saved))
    }

    var title: String {
        switch self {
        case .focus:
            return "Focus"
        case .shortBreak:
            return "Short Break"
        case .longBreak:
            return "Long Break"
        }
    }

    var shortTitle: String {
        switch self {
        case .focus:
            return "Focus"
        case .shortBreak:
            return "Short"
        case .longBreak:
            return "Long"
        }
    }

    var systemImage: String {
        switch self {
        case .focus:
            return "brain.head.profile"
        case .shortBreak:
            return "cup.and.saucer.fill"
        case .longBreak:
            return "bed.double.fill"
        }
    }

    var tint: Color {
        Color(nsColor: nsTint)
    }

    var nsTint: NSColor {
        switch self {
        case .focus:
            return Palette.focus
        case .shortBreak:
            return Palette.shortBreak
        case .longBreak:
            return Palette.longBreak
        }
    }

    /// The UserDefaults key the Settings presets are stored under.
    var defaultsKey: String {
        switch self {
        case .focus:
            return "standardTimer"
        case .shortBreak:
            return "shortBreak"
        case .longBreak:
            return "longBreak"
        }
    }

    private var defaultMinutes: Int {
        switch self {
        case .focus:
            return 25
        case .shortBreak:
            return 5
        case .longBreak:
            return 10
        }
    }

    var minutes: Int {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: defaultsKey) == nil
            ? defaultMinutes
            : defaults.integer(forKey: defaultsKey)
    }
}
