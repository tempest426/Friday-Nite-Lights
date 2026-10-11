//
//  Songformat.swift
//  Created by Michael Guzzo on 9/22/26.
//

import Foundation

//  Parses a compact text encoding of a melody into [PolyphonicChord], so a
//  song's data lives as one short string instead of one PolyphonicChord(...)
//  call per note. This is what actually solves the compile-time/space
//  problem -- not avoiding PolyphonicChord itself (the struct is cheap at
//  runtime regardless of array size), but avoiding writing dozens of struct
//  initializer calls directly as Swift source. A single string literal costs
//  the type-checker nothing extra no matter how long the song is; an array
//  literal of many nested initializer calls does.
//
//  FORMAT: space-separated events; "|" may appear as a purely visual bar
//  separator and is ignored. Each event is either:
//    - a rest:  "R:<duration>"
//    - a chord: "<pitch>[+<pitch>...]:<duration>"
//  Pitch strings are passed straight through to Pitch.note(_:), so they use
//  the same spelling that type already expects (e.g. "Eb5", "F#4", "C5").
//  Duration codes: h = half, q = quarter, e = eighth, s = sixteenth, with an
//  optional trailing "." for a dotted value. Since Duration only defines
//  whole-value cases (no fractional/dotted case), a dotted duration is
//  expanded into two chords of the same pitch(es) back to back -- the base
//  duration plus half of it -- which sound as one continuous held note.
//
//  Example: "Eb5+Eb4:h D5+D4:q. Eb5+Eb4:e" is a half-note Eb5/Eb4 dyad, a
//  dotted-quarter D5/D4 dyad, then an eighth-note Eb5/Eb4 dyad.
enum SongFormat {
    static func parse(_ source: String, velocity: UInt8 = 100) -> [PolyphonicChord] {
        var result: [PolyphonicChord] = []
        
        let tokens = source
            .split(separator: " ")
            .map(String.init)
            .filter { $0 != "|" }
        
        for token in tokens {
            guard let colonIndex = token.firstIndex(of: ":") else {
                assertionFailure("SongFormat: malformed event '\(token)' (missing ':')")
                continue
            }
            
            let head = String(token[token.startIndex..<colonIndex])
            let durationCode = String(token[token.index(after: colonIndex)...])
            
            let isDotted = durationCode.hasSuffix(".")
            let baseCode = isDotted ? String(durationCode.dropLast()) : durationCode
            
            guard let baseDuration = duration(for: baseCode) else {
                assertionFailure("SongFormat: unknown duration code '\(durationCode)' in '\(token)'")
                continue
            }
            
            let pitches: [Pitch] = (head == "R")
                ? [.rest]
                : head.split(separator: "+").map { .note(String($0)) }
            
            if isDotted, let extraDuration = halved(baseDuration) {
                result.append(PolyphonicChord(pitches, baseDuration, velocity: velocity))
                result.append(PolyphonicChord(pitches, extraDuration, velocity: velocity))
            } else {
                result.append(PolyphonicChord(pitches, baseDuration, velocity: velocity))
            }
        }
        
        return result
    }
    
    private static func duration(for code: String) -> Duration? {
        switch code {
        case "h": return .half
        case "q": return .quarter
        case "e": return .eighth
        case "s": return .sixteenth
        default: return nil
        }
    }
    
    private static func halved(_ duration: Duration) -> Duration? {
        switch duration {
        case .half: return .quarter
        case .quarter: return .eighth
        case .eighth: return .sixteenth
        default: return nil
        }
    }
}
