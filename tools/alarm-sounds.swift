// Synthesizes kyklos's own alarm sounds from sine waves, so they're original and nobody else holds rights to them.
//
//   xcrun swiftc -O tools/alarm-sounds.swift -o /tmp/alarm-sounds && /tmp/alarm-sounds <output folder>
//
// It writes one WAV per sound. Each was then brought to about the old alarm's loudness (-17 LUFS) and encoded:
//   ffmpeg -i chime.wav -af "volume=<gain>dB,alimiter=limit=0.9:level=false" -c:a pcm_s24le chime-level.wav
//   afconvert -f m4af -d aac -b 96000 chime-level.wav Timer/Sounds/Chime.m4a

import AVFoundation

let sampleRate = 48_000.0

/// One part of a struck tone: its frequency as a multiple of the note, its level, and how quickly it dies away.
struct Partial {
    let ratio: Double
    let level: Double
    /// Seconds to fall to about a third.
    let decay: Double
    /// A few hertz off, so two partials beat slowly against each other like a real bowl.
    var detune = 0.0
}

struct Instrument {
    let partials: [Partial]
    let attack: Double
    /// How far below the note each strike starts, sliding up into it: 0.3 starts 30% low. This makes a "pop".
    var glide = 0.0
    var glideTime = 0.03
    /// Cuts each note off after this long, with a short fade, like a beep rather than a ringing bar.
    var length = Double.infinity
}

struct Note {
    let time: Double
    let frequency: Double
    let velocity: Double
}

func render(_ instrument: Instrument, _ notes: [Note], length: Double) -> [Float] {
    var samples = [Double](repeating: 0, count: Int(length * sampleRate))

    for note in notes {
        let start = Int(note.time * sampleRate)

        for partial in instrument.partials {
            let frequency = note.frequency * partial.ratio + partial.detune
            let end = min(samples.count, start + Int(partial.decay * 9 * sampleRate))

            for index in start..<end {
                let t = Double(index - start) / sampleRate
                let attack = t < instrument.attack ? 0.5 - 0.5 * cos(Double.pi * t / instrument.attack) : 1
                let fading = (t - instrument.length) / 0.03
                let release = fading <= 0 ? 1 : fading < 1 ? 0.5 + 0.5 * cos(Double.pi * fading) : 0
                // Time stretched by the glide, so the pitch slides up into the note without a jump.
                let glided = t - instrument.glide * instrument.glideTime * (1 - exp(-t / instrument.glideTime))
                samples[index] += note.velocity * partial.level * attack * release * exp(-t / partial.decay)
                    * sin(2 * Double.pi * frequency * glided)
            }
        }
    }

    // Fade out the last 80 ms so the end never clicks, then scale the loudest point to full level.
    let fade = Int(0.08 * sampleRate)
    for index in max(0, samples.count - fade)..<samples.count {
        samples[index] *= Double(samples.count - index) / Double(fade)
    }
    let peak = samples.map(abs).max() ?? 1
    return samples.map { Float($0 / peak) }
}

func write(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

    let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

// Note frequencies, in hertz.
let f3 = 174.61, g3 = 196.0, c4 = 261.63, e4 = 329.63, g4 = 392.0, a4 = 440.0, c5 = 523.25, e5 = 659.26, g5 = 783.99, c6 = 1046.5, e6 = 1318.5

/// A struck metal bar: a strong fundamental and a few quickly fading, slightly out-of-tune overtones.
let bar = Instrument(partials: [
    Partial(ratio: 1, level: 1, decay: 1.4),
    Partial(ratio: 2, level: 0.12, decay: 0.7),
    Partial(ratio: 2.76, level: 0.22, decay: 0.45),
    Partial(ratio: 5.40, level: 0.08, decay: 0.18),
    Partial(ratio: 8.93, level: 0.03, decay: 0.09)
], attack: 0.002)

/// A singing bowl: long-ringing, with pairs of partials a hair apart that slowly beat.
let bowl = Instrument(partials: [
    Partial(ratio: 1, level: 1, decay: 3),
    Partial(ratio: 1, level: 0.7, decay: 3, detune: 1.6),
    Partial(ratio: 2.71, level: 0.5, decay: 2),
    Partial(ratio: 2.71, level: 0.35, decay: 2, detune: 2.3),
    Partial(ratio: 5.12, level: 0.22, decay: 1),
    Partial(ratio: 8.39, level: 0.08, decay: 0.5)
], attack: 0.004)

/// A wooden bar: short and warm, with a bright knock at the start.
let wood = Instrument(partials: [
    Partial(ratio: 1, level: 1, decay: 0.45),
    Partial(ratio: 3.93, level: 0.3, decay: 0.09),
    Partial(ratio: 9.2, level: 0.08, decay: 0.035)
], attack: 0.0015)

/// A soft electronic ping.
let ping = Instrument(partials: [
    Partial(ratio: 1, level: 1, decay: 0.25),
    Partial(ratio: 2, level: 0.15, decay: 0.12),
    Partial(ratio: 3, level: 0.05, decay: 0.06)
], attack: 0.008)

/// A felt mallet on a low wooden bar: no hard edge and almost nothing above 1 kHz, gentle on sensitive ears.
let felt = Instrument(partials: [
    Partial(ratio: 1, level: 1, decay: 0.9),
    Partial(ratio: 2, level: 0.3, decay: 0.45),
    Partial(ratio: 3, level: 0.08, decay: 0.25),
    Partial(ratio: 4, level: 0.03, decay: 0.12)
], attack: 0.012)

/// A large, low singing bowl, struck softly, with its highest ringing left out.
let lowBowl = Instrument(partials: [
    Partial(ratio: 1, level: 1, decay: 3),
    Partial(ratio: 1, level: 0.7, decay: 3, detune: 1.2),
    Partial(ratio: 2.71, level: 0.4, decay: 2),
    Partial(ratio: 2.71, level: 0.25, decay: 2, detune: 1.8),
    Partial(ratio: 5.12, level: 0.1, decay: 0.8)
], attack: 0.02)

/// A soft bubble: a round tone that slides up into its note.
let bubble = Instrument(partials: [
    Partial(ratio: 1, level: 1, decay: 0.07),
    Partial(ratio: 2, level: 0.12, decay: 0.04)
], attack: 0.004, glide: 0.35, glideTime: 0.025, length: 0.2)

/// A digital watch beep, rounded off: a softened square wave, low, with only its first two overtones.
let digital = Instrument(partials: [
    Partial(ratio: 1, level: 1, decay: 0.25),
    Partial(ratio: 3, level: 0.18, decay: 0.15),
    Partial(ratio: 5, level: 0.05, decay: 0.08)
], attack: 0.004, length: 0.11)

/// The rhythm of a digital watch alarm: two quick notes, once a second, four times.
func watchRhythm(_ first: Double, _ second: Double) -> [Note] {
    (0..<4).flatMap { beat in
        [Note(time: Double(beat), frequency: first, velocity: 0.9), Note(time: Double(beat) + 0.25, frequency: second, velocity: 1)]
    }
}

func twice(_ notes: [Note], gap: Double) -> [Note] {
    notes + notes.map { Note(time: $0.time + gap, frequency: $0.frequency, velocity: $0.velocity) }
}

let sounds: [(String, [Float])] = [
    // Two rising notes, played twice.
    ("Chime", render(bar, twice([Note(time: 0, frequency: g5, velocity: 0.8), Note(time: 0.16, frequency: c6, velocity: 1)], gap: 1.3), length: 3.6)),
    // Two strikes of a bowl.
    ("Bowl", render(bowl, [Note(time: 0, frequency: g4, velocity: 1), Note(time: 1.8, frequency: g4, velocity: 0.85)], length: 5)),
    // A quick rising arpeggio, played twice.
    ("Marimba", render(wood, twice([c5, e5, g5, c6].enumerated().map { Note(time: Double($0.offset) * 0.11, frequency: $0.element, velocity: 1) }, gap: 1), length: 2.6)),
    // Two low, soft rising notes, played twice.
    ("Felt", render(felt, twice([Note(time: 0, frequency: g3, velocity: 0.85), Note(time: 0.22, frequency: c4, velocity: 1)], gap: 1.4), length: 3.8)),
    // Two soft strikes of a low bowl.
    ("Low Bowl", render(lowBowl, [Note(time: 0, frequency: f3, velocity: 1), Note(time: 1.8, frequency: f3, velocity: 0.85)], length: 5)),
    // A watch alarm's double beep, as two soft rising pops.
    ("Pop", render(bubble, watchRhythm(e4, a4), length: 3.7)),
    // A watch alarm's double beep, rounded off and an octave and more lower.
    ("Digital", render(digital, watchRhythm(g4, g4), length: 3.7)),
    // Three pings, twice.
    ("Beacon", render(ping, twice([0, 0.14, 0.28].map { Note(time: $0, frequency: e6, velocity: $0 == 0.28 ? 1 : 0.8) }, gap: 1), length: 2.4))
]

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, samples) in sounds {
    try write(samples, to: folder.appendingPathComponent("\(name).wav"))
    print(name)
}
