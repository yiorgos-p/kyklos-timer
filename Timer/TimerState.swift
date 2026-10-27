//
//  TimerState.swift
//  Timer
//
//  Created by David on 26.07.24.
//

import Foundation
import SwiftUI

enum TimerState {
    case running
    case paused
    case stopped
    /// The countdown reached zero and is now counting overtime until the next phase is started.
    case finished
}

enum TimerPhase: CaseIterable {
    case focus
    case shortBreak
    case longBreak

    /// A long break comes after every this many focus sessions.
    static let focusSessionsPerLongBreak = 4

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
        switch self {
        case .focus:
            return .accentColor
        case .shortBreak:
            return .green
        case .longBreak:
            return .indigo
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
