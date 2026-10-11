import Foundation
import AVFoundation

// MARK: - Musical Models

enum Duration {
    case whole, half, quarter, eighth, sixteenth
    
    func seconds(bpm: Double = 120.0) -> Double {
        let quarterNoteDuration = 60.0 / bpm
        switch self {
        case .whole:     return quarterNoteDuration * 4.0
        case .half:      return quarterNoteDuration * 2.0
        case .quarter:   return quarterNoteDuration
        case .eighth:    return quarterNoteDuration / 2.0
        case .sixteenth: return quarterNoteDuration / 4.0
        }
    }
}

enum Pitch {
    case rest
    case note(String) // e.g. "A4", "C#5", "Bb3"
    case midi(UInt8)  // Direct MIDI note number (0...127)
    
    var midiNote: UInt8? {
        switch self {
        case .rest:
            return nil
        case .midi(let note):
            return note
        case .note(let name):
            return pitchToMIDI(name)
        }
    }
    
    // Compiled once and reused: this used to be rebuilt from scratch on
    // every single note (i.e. every chord, of every score, on every pass
    // through a looping halftime tune), which is pure repeated overhead
    // since the pattern never changes.
    private static let noteNameRegex = try? NSRegularExpression(pattern: "^([A-Ga-g])([#b]?)(-?\\d+)$")

    private func pitchToMIDI(_ name: String) -> UInt8? {
        guard let regex = Pitch.noteNameRegex,
              let match = regex.firstMatch(in: name, range: NSRange(location: 0, length: name.utf16.count)) else {
            return nil
        }
        
        let nsString = name as NSString
        let noteName = nsString.substring(with: match.range(at: 1)).uppercased()
        let accidental = nsString.substring(with: match.range(at: 2))
        let octaveStr = nsString.substring(with: match.range(at: 3))
        
        guard let octave = Int(octaveStr) else { return nil }
        
        let baseOffsets: [String: Int] = [
            "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
        ]
        
        guard var noteValue = baseOffsets[noteName] else { return nil }
        
        if accidental == "#" { noteValue += 1 }
        else if accidental == "b" { noteValue -= 1 }
        
        let midi = (octave + 1) * 12 + noteValue
        return UInt8(clamping: midi)
    }
}

struct MusicalNote {
    let pitch: Pitch
    let duration: Duration
    let velocity: UInt8
    
    init(_ pitch: Pitch, _ duration: Duration, velocity: UInt8 = 100) {
        self.pitch = pitch
        self.duration = duration
        self.velocity = velocity
    }
}

struct PolyphonicChord {
    let pitches: [Pitch]
    let duration: Duration
    let velocity: UInt8
    
    init(_ pitches: [Pitch], _ duration: Duration, velocity: UInt8 = 100) {
        self.pitches = pitches
        self.duration = duration
        self.velocity = velocity
    }
    
    init(_ note: MusicalNote) {
        self.pitches = [note.pitch]
        self.duration = note.duration
        self.velocity = note.velocity
    }
}

/// Which sampler/patch a given sound plays through. `.chiptune` is the
/// existing square-wave-ish system DLS patch used for all game SFX;
/// `.melodic` is a second sampler loaded from a bundled General MIDI
/// SoundFont (.sf2), used for real-instrument playback like the halftime
/// show's marching-band tune. See the accompanying README for how to add
/// the .sf2 file itself.
enum Instrument {
    case chiptune
    case melodic
}

enum SoundEngineError: LocalizedError {
    case missingSoundFont(String)
    
    var errorDescription: String? {
        switch self {
        case .missingSoundFont(let name):
            return "Missing \(name).sf2 in the app bundle. Add it to the project (as a plain bundled resource, not an asset catalog entry) and confirm its target membership."
        }
    }
}

// MARK: - Updated Sound Engine

// @MainActor
class AppleIISoundEngine {
    static let shared = AppleIISoundEngine()
    
    private let audioEngine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()          // chiptune SFX (existing)
    private let melodicSampler = AVAudioUnitSampler()   // real-instrument playback (new)
    
    init() {
        audioEngine.attach(sampler)
        audioEngine.attach(melodicSampler)
        
        // Both samplers route through mainMixerNode rather than outputNode
        // directly: outputNode only takes one input connection on bus 0, so
        // two samplers connected straight to it would fight over that single
        // slot and one would silently go unheard. mainMixerNode is built to
        // sum multiple inputs, and AVAudioEngine auto-connects it to
        // outputNode the first time it's accessed, so no extra wiring is
        // needed beyond connecting each sampler to the mixer.
        let mixer = audioEngine.mainMixerNode
        let format = audioEngine.outputNode.inputFormat(forBus: 0)
        audioEngine.connect(sampler, to: mixer, format: format)
        audioEngine.connect(melodicSampler, to: mixer, format: format)
        
        func loadDefaultSoundBank() {
            guard let bankURL = soundBankURL() else { return }
            try? sampler.loadSoundBankInstrument(
                at: bankURL,
                program: 61, // General MIDI Program 80 = Square wave / Chiptune
                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB)
            )
        }
        
        do {
            try audioEngine.start()
            loadDefaultSoundBank()
            try? loadMelodicSoundFont()   // no-ops quietly if the .sf2 isn't bundled yet
        } catch {
            print("Audio engine failed to start: \(error)")
        }
    }
    
    
    
    private func soundBankURL() -> URL? {
        let defaultPath = "/System/Library/Components/CoreAudio.component/Contents/Resources/SystemSounds/bank36.dls"
        if FileManager.default.fileExists(atPath: defaultPath) {
            return URL(fileURLWithPath: defaultPath)
        }
        return nil
    }
    
    /// Loads a bundled General MIDI SoundFont (.sf2) into the melodic
    /// sampler. `program` is the 0-indexed General MIDI program number
    /// (61 = Brass Section, a reasonable default for a march). Throws if the
    /// named file isn't in the app bundle, so callers that want to know
    /// about a missing/misconfigured resource can -- unlike the existing
    /// chiptune loader, which fails silently by design since that soundbank
    /// is a system file that's either there or it isn't.
    func loadMelodicSoundFont(named name: String = "GeneralMIDI", program: UInt8 = 61) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "sf2") else {
            throw SoundEngineError.missingSoundFont(name)
        }
        try melodicSampler.loadSoundBankInstrument(
            at: url,
            program: program,
            bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
            bankLSB: 0
        )
        
        melodicSampler.sendProgramChange(program, onChannel: 0)
    }
    
    private func activeSampler(for instrument: Instrument) -> AVAudioUnitSampler {
        switch instrument {
        case .chiptune: return sampler
        case .melodic:  return melodicSampler
        }
    }
    
    // MARK: - Polyphonic MIDI Core Methods
    
    func startNote(pitch: Pitch, velocity: UInt8 = 100, instrument: Instrument = .melodic) {
        guard let note = pitch.midiNote else { return }
        activeSampler(for: instrument).startNote(note, withVelocity: velocity, onChannel: 0)
    }
    
    func stopNote(pitch: Pitch, instrument: Instrument = .melodic) {
        guard let note = pitch.midiNote else { return }
        activeSampler(for: instrument).stopNote(note, onChannel: 0)
    }
    
    func playChord(_ chord: PolyphonicChord, bpm: Double = 120.0, instrument: Instrument = .melodic) async {
        let durationSeconds = chord.duration.seconds(bpm: bpm)
        let midiNotes = chord.pitches.compactMap { $0.midiNote }
        let sampler = activeSampler(for: instrument)
        
        for note in midiNotes {
            sampler.startNote(note, withVelocity: chord.velocity, onChannel: 0)
        }
        
        let nanoseconds = UInt64(durationSeconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
        
        for note in midiNotes {
            sampler.stopNote(note, onChannel: 0)
        }
    }
    
    func playScore(_ score: [PolyphonicChord], bpm: Double = 120.0, instrument: Instrument = .chiptune) async {
        for chord in score {
            if Task.isCancelled { break }
            await playChord(chord, bpm: bpm, instrument: instrument)
        }
    }

    // MARK: - Retro Game SFX & Fanfares
    
    func playCoinTick() {
        Task { @MainActor in
            await playChord(PolyphonicChord([.note("A5")], .sixteenth))
        }
    }
    
    func playWhistle() {
        Task { @MainActor in
            let score: [PolyphonicChord] = [
                PolyphonicChord([.note("A6")], .sixteenth),
                PolyphonicChord([.note("B6")], .sixteenth),
                PolyphonicChord([.note("C#7")], .eighth)
            ]
            await playScore(score, bpm: 200.0)
        }
    }
    
    func playStep() {
        Task { @MainActor in
            await playChord(PolyphonicChord([.note("C2")], .sixteenth, velocity: 60))
        }
    }
    
    func playTouchdownFanfare() {
        Task { @MainActor in
            let score: [PolyphonicChord] = [
                PolyphonicChord([.note("C4"), .note("E4"), .note("G4")], .eighth),
                PolyphonicChord([.note("E4"), .note("G4"), .note("C5")], .eighth),
                PolyphonicChord([.note("G4"), .note("C5"), .note("E5")], .eighth),
                PolyphonicChord([.note("C5"), .note("E5"), .note("G5")], .half)
            ]
            await playScore(score, bpm: 140.0)
        }
    }
    
    func playOpeningTheme() {
        Task { @MainActor in
            let score: [PolyphonicChord] = [
                PolyphonicChord([.note("G4")], .eighth),
                PolyphonicChord([.note("A4")], .eighth),
                PolyphonicChord([.note("C5")], .quarter),
                PolyphonicChord([.note("C5")], .eighth),
                PolyphonicChord([.note("D5")], .eighth),
                PolyphonicChord([.note("E5")], .quarter),
                PolyphonicChord([.note("E5"), .note("G5")], .half)
            ]
            await playScore(score, bpm: 130.0)
        }
    }

    // MARK: - Halftime Show Music
    
    /// The halftime tune's 4-bar intro, played once. The real piece's own
    /// tempo marking is ~quarter note = 240 (a brisk cut-time march feel),
    /// hence the higher default bpm than the SFX above.
    func playHalftimeIntro(bpm: Double = 240) async {
        await playScore(StarsAndStripesSong.intro, bpm: bpm, instrument: .melodic)
    }
    
    /// The halftime tune's repeatable section, played once through. Call
    /// this in a loop (see README) for continuous playback until dismissed
    /// -- playScore already checks Task.isCancelled between chords, so a
    /// cancellable Task wrapping the loop is all that's needed to stop it
    /// cleanly mid-phrase rather than only at the end of a full pass.
    func playHalftimeLoop(bpm: Double = 240) async {
        await playScore(StarsAndStripesSong.loopBody, bpm: bpm, instrument: .melodic)
    }
}
