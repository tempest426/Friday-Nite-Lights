//
//  SongData.swift
//
//  Created by Michael Guzzo on 9/22/26.
//

import Foundation

//  Source and verification: Mutopia Project public-domain piano reduction
//  (Music ID Mutopia-2005/11/09-626, typeset by Benjamin Bloomfield),
//  transcribed by parsing its LilyPond source per LilyPond's own documented
//  relative-octave algorithm rather than by ear. Round-trip checked against
//  the original note-by-note data before being re-encoded into this compact
//  form -- nothing here was re-transcribed by hand.
//
//  Split into exactly what a looping player needs:
//    - intro:    Bars 1-4, the fanfare. Played once, at the start.
//    - loopBody: Bars 5-20 of the First Strain, using the real score's
//                "first ending" (the one that repeats back to Bar 5), not
//                the "second ending" that resolves forward into the Second
//                Strain -- so looping it indefinitely is musically correct,
//                not just repeated-and-cut-off.
enum StarsAndStripesSong {
    // Swift initializes `static let`s lazily (on first access) and only
    // once, so this keeps the "parse on demand" behavior of the old
    // computed vars but without re-tokenizing the string on every repeat
    // of the halftime loop.
    static let intro: [PolyphonicChord] = SongFormat.parse(introData)
    
    static let loopBody: [PolyphonicChord] = SongFormat.parse(loopBodyData)
    
    // Bars 1-4 (Intro fanfare) -- played once.
    private static let introData =
        "Eb5+Eb4:h D5+D4:q. Eb5+Eb4:e C5+C4:q Eb5+Eb4:h F5+F4:q " +
        "Gb5+Gb4:q G5+G4:q Ab5+Ab4:q A5+A4:q Bb5+Bb4:q R:q Bb4:h"
    
    // Bars 5-20 (First Strain, first/repeat ending) -- loop indefinitely.
    private static let loopBodyData =
        "G5+Bb4:q R:e G5+Bb4:e G5+B4:q G5+B4:q " +
        "G5+C5:q R:e G5+C5:e Ab5+C5:q Ab5+C5:q " +
        "F5:e E5:e F5:e G5:e F5:q Eb5:q " +
        "D5:q C5:q D5:q Bb4:q " +
        "Bb5+Bb4:q R:e Bb5+Bb4:e Bb5+Bb4:q Bb5+Bb4:q " +
        "Bb5+Bb4:q R:e Bb5+Bb4:e B5+B4:q B5+B4:q " +
        "C6+C5:e B5:e C6:e Eb6:e D6:q C6+C5:q " +
        "B5+B4:h. B5+B4:q " +
        "Bb5+Bb4:q R:e Bb5:e Eb6:q R:e C6:e " +
        "Bb5:q A5:q Bb5:q G5:q " +
        "F5:q Bb4:e A4:e Bb4:e A4:e Bb4:q " +
        "F5:q Bb4:e A4:e Bb4:e A4:e Bb4:q " +
        "Bb5+Bb4:q R:e Bb5:e Eb6:q R:e C6:e " +
        "Bb5:q A5:q Bb5:q Gb5:q " +
        "F5:q A4:e G4:e A4:e G4:e A4:q " +
        "Bb4:q R:q Bb4:h"
}
