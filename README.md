# Anchor

Anchor is a free, minimal Pomodoro timer for macOS, in its own window and in the menu bar. It is built to keep a
wandering mind on one thing at a time.

Anchor is based on [Cloud](https://github.com/YYUUGGOO/Cloud) by David.

## Features

- Focus, Short Break and Long Break, with a long break after every 4 focus sessions (2 to 8, your choice)
- When time is up, the timer counts the overtime and offers to start the next phase with one click
- A "What are you working on?" line, shown in the window and next to the time in the menu bar
- A 60-minute dial: the coloured wedge is the time left, so 25 minutes always looks like 25 minutes, plus the time it will end
- Set the length with − and + beside the dial, or pick Focus, Short Break or Long Break
- Today's finished focus sessions, shown as dots, with a button to reset them
- Accurate to the system clock: keeps counting through sleep and never drifts
- A notification and an alarm when time is up, with the alarm ringing again every minute for up to 10 minutes
- A global shortcut to start or pause from any app: ⌃⌥A, or one you pick
- Optional mouse mode: click the dial to start or pause, and triple-click it to reset
- Optional Zen Mode that hides the phase switcher and − / + while the timer is running
- Optional Minimal Mode: a small floating pill with the time, the task and one button, shown during a session or all the time
- A window that can stay on top of other windows
- Light and Dark Mode, following your Mac or set by hand
- Launch at Login support
- No ads and no data collection

## Requirements

- macOS 14 or later
- Xcode with support for building macOS 14 applications

## Build from source

1. Open `Timer.xcodeproj` in Xcode.
2. Allow Xcode to resolve the Swift package dependency.
3. Select the `Timer` scheme and build or run the app.

No Apple developer account is needed: the app is signed to run locally. To build from the command line:

```sh
xcodebuild -project Timer.xcodeproj -scheme Timer -configuration Release -derivedDataPath build build
```

The app ends up in `build/Build/Products/Release/Anchor.app`.

## Dependency

- [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern)

## License

Anchor is licensed under the GNU General Public License v3.0, like the Cloud project it is based on.
