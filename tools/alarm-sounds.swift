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
            let step = 2 * Double.pi * frequency / sampleRate
            let end = min(samples.count, start + Int(partial.decay * 9 * sampleRate))

            for index in start..<end {
                let t = Double(index - start) / sampleRate
                let attack = t < instrument.attack ? 0.5 - 0.5 * cos(Double.pi * t / instrument.attack) : 1
                samples[index] += note.velocity * partial.level * attack * exp(-t / partial.decay)
                    * sin(step * Double(index - start))
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
let g4 = 392.0, c5 = 523.25, e5 = 659.26, g5 = 783.99, c6 = 1046.5, e6 = 1318.5

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
    // Three pings, twice.
    ("Beacon", render(ping, twice([0, 0.14, 0.28].map { Note(time: $0, frequency: e6, velocity: $0 == 0.28 ? 1 : 0.8) }, gap: 1), length: 2.4))
]

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, samples) in sounds {
    try write(samples, to: folder.appendingPathComponent("\(name).wav"))
    print(name)
}
