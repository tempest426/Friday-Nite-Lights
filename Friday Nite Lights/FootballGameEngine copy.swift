//
//  FootballGameEngine.swift
//  Friday Nite Lights
//

import Foundation
import Combine
import SwiftUI

enum GamePhase {
    case introTitle
    case coinToss
    case playSelection
    case animatingPlay
    case extraPointSelection
    case halftime
    case gameOver
}

enum OffensePlay: String, CaseIterable, Identifiable {
    case runInside = "RUN INSIDE"
    case runOutside = "RUN OUTSIDE"
    case pitch = "PITCH"
    case shortPass = "SHORT PASS"
    case longPass = "LONG PASS"
    case screenPass = "SCREEN PASS"
    case playAction = "PLAY ACTION"
    case trickPlay = "TRICK PLAY"
    case punt = "PUNT"
    case fieldGoal = "FIELD GOAL"
    
    var id: String { self.rawValue }
    var name: String { self.rawValue }
}

enum DefenseScheme: String, CaseIterable, Identifiable {
    case standard = "STANDARD (4-3)"
    case runStack = "RUN STACK (8-BOX)"
    case passBlitz = "PASS BLITZ"
    case nickel = "NICKEL (4-2-5)"
    case dime = "DIME (4-1-6)"
    case prevent = "PREVENT"
    case goalLineStand = "GOAL LINE STAND"
    case specialTeams = "SPECIAL TEAMS"
    
    var id: String { self.rawValue }
    var name: String { self.rawValue }
}

struct TeamRoster {
    let name: String
    let qb: String
    let rb: String
    let wr: String
    let def: String
}

@MainActor
final class FootballGameEngine: ObservableObject {
    @Published var gamePhase: GamePhase = .introTitle
    @Published var logOutput: [String] = []
    @Published var possessingTeam: Int = 0
    @Published var scores: [Int] = [0, 0]
    @Published var quarter: Int = 1
    @Published var timeRemaining: Int = 900
    @Published var down: Int = 1
    @Published var yardsToGain: Int = 10
    @Published var yardLine: Int = 20
    
    @Published var isFlippingCoin: Bool = false
    @Published var coinFlipDisplay: String = "HEADS"
    @Published var coinYOffset: CGFloat = 0
    
    @Published var isKicking: Bool = false
    @Published var kickMeterPosition: Double = 0.5
    
    // Final game summary (shown in .gameOver)
    @Published var finalSummaryLines: [String] = []
    
    let teams = ["BUFFALO", "KANSAS CITY"]
    let rosters = [
        TeamRoster(name: "BUFFALO", qb: "ALLEN", rb: "COOK", wr: "MOORE", def: "BILLS DEFENSE"),
        TeamRoster(name: "KANSAS CITY", qb: "MAHOMES", rb: "WALKER", wr: "RICE", def: "CHIEFS DEFENSE")
    ]
    
    let offensivePlays = OffensePlay.allCases
    let defensivePlays = DefenseScheme.allCases
    
    let soundEngine: AppleIISoundEngine
    @Published var graphicsEngine: AppleIIGraphicsEngine
    
    @Published var teamStats: [TeamStats] = [TeamStats(), TeamStats()]
    let halftimeShow: HalftimeShowEngine
    
    private var currentDefenseScheme: DefenseScheme = .standard
    
    var clockSeconds: Int { timeRemaining }
    
    private var isInInterludePhase: Bool {
        gamePhase == .halftime || gamePhase == .gameOver
    }
    
    var formattedClock: String {
        let mins = timeRemaining / 60
        let secs = timeRemaining % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    var isGoalToGo: Bool {
        let distanceToGoal = possessingTeam == 0 ? (100 - yardLine) : yardLine
        return distanceToGoal <= 10
    }
    
    var formattedYardLine: String {
        if yardLine == 50 {
            return "50 YD LINE"
        }
        
        let distance: Int
        let isOwnTerritory: Bool
        
        if possessingTeam == 0 {
            isOwnTerritory = yardLine < 50
            distance = isOwnTerritory ? yardLine : (100 - yardLine)
        } else {
            isOwnTerritory = yardLine > 50
            distance = isOwnTerritory ? (100 - yardLine) : yardLine
        }
        
        let territoryPrefix = isOwnTerritory ? "OWN" : "OPP"
        return "\(territoryPrefix) \(distance)"
    }
    
    init() {
        let graphics = AppleIIGraphicsEngine()
        let sound = AppleIISoundEngine.shared
        
        self.graphicsEngine = graphics
        self.soundEngine = sound
        self.halftimeShow = HalftimeShowEngine(graphicsEngine: graphics, soundEngine: sound)
        
        startOpeningSequence()
    }
    
    private static let maxLogLines = 10
    
    func appendLog(_ message: String) {
        logOutput.append(message)
        if logOutput.count > Self.maxLogLines {
            logOutput.removeFirst(logOutput.count - Self.maxLogLines)
        }
    }
    
    private func returnToPlaySelectionIfNeeded() {
        if !isInInterludePhase {
            gamePhase = .playSelection
            updateFieldGraphics()
        }
    }
    
    // MARK: - Game Flow
    
    func startOpeningSequence() {
        gamePhase = .introTitle
        logOutput.removeAll()
        finalSummaryLines = []
        
        Task { @MainActor in
            await graphicsEngine.playStartupAnimation {
            }

            appendLog("****************************************")

            let textLine = "Lake Effect Software"

            Task { @MainActor [weak self] in
                guard let self else { return }

                for charIndex in 1...textLine.count {
                    try? await Task.sleep(nanoseconds: 50_000_000)

                    self.soundEngine.playCoinTick()
                    self.appendLog(String(textLine.prefix(charIndex)))
                }

                self.appendLog("PRESENTS...")

                try? await Task.sleep(nanoseconds: 800_000_000)

                self.appendLog("")
                self.appendLog("=== FRIDAY NITE LIGHTS ===")
                self.appendLog("Based on the Apple][ game TUESDAY NITE FOOTBALL ==")
                self.appendLog("=== (C) 1982 Shoestring Software ===")
                self.appendLog("PRESS 'START COIN TOSS' TO BEGIN")
                self.soundEngine.playOpeningTheme()
            }
        }
    }
    
    func triggerCoinToss(choice: String = "HEADS") {
        guard gamePhase == .introTitle || gamePhase == .coinToss else { return }

        gamePhase = .coinToss
        isFlippingCoin = true
        coinYOffset = 0
        logOutput.removeAll()
        appendLog("FLIPPING COIN...")

        let totalTicks = 24

        Task { @MainActor [weak self] in
            guard let self else { return }

            for ticks in 1...totalTicks {
                try? await Task.sleep(nanoseconds: 60_000_000)

                self.coinFlipDisplay = (ticks % 2 == 0) ? "HEADS" : "TAILS"

                let progress = Double(ticks) / Double(totalTicks)
                self.coinYOffset = -CGFloat(sin(progress * .pi)) * 80.0

                self.soundEngine.playCoinTick()
            }

            self.isFlippingCoin = false
            self.coinYOffset = 0

            let winner = Int.random(in: 0...1)

            self.possessingTeam = winner
            self.yardLine = (winner == 0) ? 20 : 80
            self.down = 1
            self.yardsToGain = 10
            self.quarter = 1
            self.timeRemaining = 900
            self.scores = [0, 0]
            self.teamStats = [TeamStats(), TeamStats()]
            self.finalSummaryLines = []

            self.soundEngine.playWhistle()
            self.appendLog("\(self.teams[winner]) WINS THE TOSS AND RECEIVES!")
            self.appendLog("FIRST DOWN AT THE \(self.formattedYardLine).")

            try? await Task.sleep(nanoseconds: 1200_000_000)

            self.gamePhase = .playSelection
            self.updateFieldGraphics()
        }
    }
    
    func updateFieldGraphics(offensiveOffset: Int = 0) {
        graphicsEngine.drawField(
            yardLine: yardLine,
            down: down,
            yardsToGain: yardsToGain,
            possessingTeam: possessingTeam,
            offensiveOffset: offensiveOffset
        )
    }
    
    // MARK: - Play Selection & Animation
    
    func selectOffensivePlay(_ play: OffensePlay) {
        selectPlay(offensePlay: play)
    }
    
    func selectDefensivePlay(_ scheme: DefenseScheme) {
        guard gamePhase == .playSelection else { return }
        gamePhase = .animatingPlay
        
        currentDefenseScheme = scheme
        
        if down == 4 {
            switch decideAIFourthDown() {
            case .fieldGoal:
                executeFieldGoal()
                return
            case .punt:
                executePunt()
                return
            case .goForIt:
                break
            }
        }
        
        let randomOffense = OffensePlay.allCases.filter { $0 != .punt && $0 != .fieldGoal }.randomElement() ?? .runInside
        executeScrimmagePlay(offense: randomOffense, defense: scheme)
    }
    
    private enum AIFourthDownDecision {
        case fieldGoal
        case punt
        case goForIt
    }
    
    private func decideAIFourthDown() -> AIFourthDownDecision {
        let distanceToGoal = possessingTeam == 0 ? (100 - yardLine) : yardLine
        let opponent = possessingTeam == 0 ? 1 : 0
        let trailingBy = scores[opponent] - scores[possessingTeam]
        
        let isTwoMinuteDrill = (quarter == 2 || quarter == 4) && timeRemaining < 150
        let lateFGFuzz = isTwoMinuteDrill ? 10 : 0
        
        if distanceToGoal > Int.random(in: 0...3) && distanceToGoal < 25 + Int.random(in: 0...9) + lateFGFuzz {
            return .fieldGoal
        }
        
        if distanceToGoal < 30 + Int.random(in: 0...9) + lateFGFuzz && yardsToGain > 6 {
            return .fieldGoal
        }
        
        if distanceToGoal < 35 + Int.random(in: 0...9) {
            return .goForIt
        }
        
        if quarter == 4 && timeRemaining < 240 && trailingBy > 7 {
            return .goForIt
        }
        
        return .punt
    }
    
    func selectPlay(offensePlay: OffensePlay) {
        guard gamePhase == .playSelection else { return }
        gamePhase = .animatingPlay
        
        let defenseScheme = selectAIDefenseScheme()
        currentDefenseScheme = defenseScheme
        
        switch offensePlay {
        case .punt:
            executePunt()
        case .fieldGoal:
            executeFieldGoal()
        default:
            executeScrimmagePlay(offense: offensePlay, defense: defenseScheme)
        }
    }
    
    private func selectAIDefenseScheme() -> DefenseScheme {
        let distanceToGoal = possessingTeam == 0 ? (100 - yardLine) : yardLine

        if down == 4 || yardsToGain >= 15 {
            if Double.random(in: 0...1) < 0.35 {
                return .specialTeams
            }
        }

        let shortYardageFactor = (yardsToGain < 5 && down > 2)
            ? Double(5 * (5 - yardsToGain) + 15 * (down - 2)) * 0.02
            : 0.0

        let goalLineProximityFactor = distanceToGoal < 15
            ? Double(30 - distanceToGoal) * 0.035
            : 0.0

        let goalLineCallChance = max(shortYardageFactor, goalLineProximityFactor)
        if goalLineCallChance > 0 && Double.random(in: 0...1) < goalLineCallChance {
            return .goalLineStand
        }

        if yardsToGain >= 15 {
            return Double.random(in: 0...1) > 0.4 ? .prevent : .dime
        } else if yardsToGain <= 2 && down >= 3 {
            return .runStack
        } else {
            let roll = Int.random(in: 1...100)
            if roll <= 30 { return .standard }
            if roll <= 50 { return .runStack }
            if roll <= 70 { return .passBlitz }
            if roll <= 85 { return .nickel }
            return .dime
        }
    }
    
    func animatePlayMovement(yards: Int, completion: @escaping () -> Void) {
        let totalFrames = 10
        let stepYard = yards / totalFrames

        Task { @MainActor [weak self] in
            guard let self else { return }

            for frame in 1...totalFrames {
                try? await Task.sleep(nanoseconds: 33_000_000)

                self.soundEngine.playStep()
                self.updateFieldGraphics(
                    offensiveOffset: frame * stepYard
                )
            }

            completion()
        }
    }
    
    private func cappedAnimationYards(_ yards: Int) -> Int {
        if yards >= 0 {
            let distanceToOpponentGoal = possessingTeam == 0 ? (100 - yardLine) : yardLine
            return min(yards, distanceToOpponentGoal)
        } else {
            let distanceToOwnGoal = possessingTeam == 0 ? yardLine : (100 - yardLine)
            return -min(-yards, distanceToOwnGoal)
        }
    }
    
    func executeScrimmagePlay(offense: OffensePlay, defense: DefenseScheme) {
        let offRoster = rosters[possessingTeam]
        let defRoster = rosters[possessingTeam == 0 ? 1 : 0]
        
        appendLog("\(teams[possessingTeam])\(randomBreakFromHuddle())")
        appendLog("\(offRoster.qb)\(randomSignals()) THE SIGNALS...")
        appendLog("...AND HERE'S THE \(randomSnap()):")
        
        describePlayCall(offense: offense, qb: offRoster.qb, rb: offRoster.rb, wr: offRoster.wr)
        
        // Sack Check
        if (offense == .shortPass || offense == .longPass || offense == .playAction) && defense == .passBlitz {
            if Double.random(in: 0...1) < 0.35 {
                let loss = Int.random(in: 4...10)
                appendLog("HE'S \(randomPressure())…")
                animatePlayMovement(yards: cappedAnimationYards(-loss)) {
                    self.appendLog("\(offRoster.qb) SACKED!!")
                    self.appendLog("\(self.randomTackleVerb()) BY \(defRoster.def) FOR A LOSS OF \(loss) YARDS.")
                    self.advanceClock(seconds: Int.random(in: 20...30))
                    self.resolvePlayResult(yardsGained: -loss, offense: offense)
                }
                return
            }
        }
        
        // Interception Check
        if offense == .shortPass || offense == .longPass || offense == .screenPass || offense == .playAction {
            var intChance = 0.03
            if offense == .longPass { intChance += 0.08 }
            if defense == .prevent || defense == .dime { intChance += 0.06 }
            
            if Double.random(in: 0...1) < intChance {
                let passDepth: Int
                switch offense {
                case .longPass: passDepth = Int.random(in: 12...30)
                case .screenPass: passDepth = Int.random(in: 0...4)
                default: passDepth = Int.random(in: 5...15)
                }
                
                teamStats[possessingTeam].turnovers += 1
                
                appendLog("\(offRoster.qb) \(randomDropBack()) BACK TO PASS")
                if Bool.random() { appendLog("HE'S \(randomPressure())…") }
                
                animatePlayMovement(yards: cappedAnimationYards(passDepth)) {
                    self.resolveInterception(passDepth: passDepth, defRoster: defRoster)
                }
                return
            }
        }
        
        // Completion Check
        var isCompletion = true
        if offense == .shortPass || offense == .longPass || offense == .screenPass || offense == .playAction {
            var compChance = 0.65
            if offense == .longPass { compChance = 0.40 }
            if offense == .screenPass { compChance = 0.75 }
            
            if Double.random(in: 0...1) > compChance {
                isCompletion = false
            }
        }
        
        if !isCompletion {
            appendLog("\(offRoster.qb) \(randomDropBack()) BACK TO PASS")
            if Bool.random() { appendLog("HE'S \(randomPressure())…") }
            appendLog("PASS INCOMPLETE")
            if Bool.random() {
                appendLog("DROPPED!!--BY \(offRoster.wr)")
            } else {
                appendLog("INTENDED FOR \(offRoster.wr)")
                appendLog("BROKEN UP BY \(defRoster.def)")
            }
            advanceClock(seconds: 6)
            resolvePlayResult(yardsGained: 0, offense: offense)
            return
        }
        
        let yardsGained = calculateYardage(offense: offense, defense: defense)
        
        if offense == .shortPass || offense == .longPass || offense == .screenPass || offense == .playAction {
            appendLog("\(offRoster.qb) \(randomDropBack()) BACK TO PASS")
            if Bool.random() { appendLog("HE'S \(randomPressure())…") }
        }
        
        animatePlayMovement(yards: cappedAnimationYards(yardsGained)) {
            self.advanceClock(seconds: Int.random(in: 15...35))
            self.resolvePlayResult(yardsGained: yardsGained, offense: offense)
        }
    }
    
    private func calculateYardage(offense: OffensePlay, defense: DefenseScheme) -> Int {
        var base = 0
        var variance = 0
        
        switch offense {
        case .runInside:
            if defense == .goalLineStand {
                base = -3
            } else {
                base = (defense == .runStack) ? -1 : ((defense == .prevent) ? 5 : 3)
            }
            variance = (defense == .goalLineStand) ? Int.random(in: -3...3) : Int.random(in: -2...6)
        case .runOutside, .pitch:
            if defense == .goalLineStand {
                base = -2
            } else {
                base = (defense == .runStack) ? -3 : ((defense == .passBlitz) ? 6 : 4)
            }
            variance = (defense == .goalLineStand) ? Int.random(in: -3...4) : Int.random(in: -3...10)
        case .shortPass:
            if defense == .goalLineStand {
                base = 9
            } else {
                base = (defense == .prevent) ? 4 : ((defense == .runStack) ? 10 : 7)
            }
            variance = (defense == .goalLineStand) ? Int.random(in: -2...10) : Int.random(in: -1...5)
        case .longPass:
            if defense == .goalLineStand {
                base = 22
            } else {
                base = (defense == .prevent || defense == .dime) ? 8 : ((defense == .passBlitz) ? 28 : 18)
            }
            variance = (defense == .goalLineStand) ? Int.random(in: -5...25) : Int.random(in: -5...20)
        case .screenPass:
            if defense == .goalLineStand {
                base = 12
            } else {
                base = (defense == .passBlitz) ? 14 : ((defense == .runStack) ? -2 : 5)
            }
            variance = (defense == .goalLineStand) ? Int.random(in: 0...10) : Int.random(in: -2...8)
        case .playAction:
            if defense == .goalLineStand {
                base = 20
            } else {
                base = (defense == .runStack) ? 16 : ((defense == .dime) ? 3 : 8)
            }
            variance = (defense == .goalLineStand) ? Int.random(in: -3...15) : Int.random(in: -2...12)
        case .trickPlay:
            let success = Double.random(in: 0...1) < 0.35
            base = success ? 25 : -5
            variance = Int.random(in: -3...10)
        default:
            base = 0
        }
        
        return max(-8, base + variance)
    }

    // MARK: - Special Teams

    private func attemptSpecialTeamsBlock(isFieldGoal: Bool) -> Bool {
        guard currentDefenseScheme == .specialTeams else { return false }
        
        // Base 3 % with ± 2 % random fuzz, clamped to 1–5 %
        let blockChance = max(0.01, min(0.05, 0.03 + Double.random(in: -0.02...0.02)))
        guard Double.random(in: 0...1) < blockChance else { return false }

        let recoveringTeam = (possessingTeam == 0) ? 1 : 0
        let defName = rosters[recoveringTeam].def

        soundEngine.playWhistle()
        appendLog("***** BLOCKED !!!!! *****")
        appendLog("\(defName) GETS A HAND ON IT!!!")

        let blockSpot: Int
        if possessingTeam == 0 {
            blockSpot = max(1, yardLine - Int.random(in: 5...12))
        } else {
            blockSpot = min(99, yardLine + Int.random(in: 5...12))
        }

        possessingTeam = recoveringTeam
        yardLine = blockSpot
        down = 1
        yardsToGain = 10

        if isFieldGoal {
            appendLog("FIELD GOAL BLOCKED! \(teams[recoveringTeam]) TAKE OVER AT THE \(formattedYardLine).")
        } else {
            appendLog("PUNT BLOCKED! \(teams[recoveringTeam]) TAKE OVER AT THE \(formattedYardLine).")
        }

        if Double.random(in: 0...1) < 0.12 {
            appendLog("AND HE'S OFF TO THE RACES... TOUCHDOWN \(teams[recoveringTeam])!!!!")
            scores[recoveringTeam] += 6
            soundEngine.playTouchdownFanfare()
            yardLine = recoveringTeam == 0 ? 100 : 0
            updateFieldGraphics()
            if recoveringTeam == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.gamePhase = .extraPointSelection
                }
            } else {
                gamePhase = .extraPointSelection
                executeAIExtraPoint()
            }
            return true
        }

        returnToPlaySelectionIfNeeded()
        return true
    }

    func executePunt() {
        // Special-Teams block check first
        if attemptSpecialTeamsBlock(isFieldGoal: false) {
            advanceClock(seconds: 8)
            return
        }

        let kickingTeam = possessingTeam
        let direction = kickingTeam == 0 ? 1 : -1
        
        appendLog("\(teams[kickingTeam]) PUNTS THE BALL...")
        soundEngine.playWhistle()
        
        gamePhase = .animatingPlay
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            await self.graphicsEngine.playKickAnimation(
                startYardLine: self.yardLine,
                isFieldGoal: false,
                direction: direction
            ) { isGood, finalYard in
                
                self.advanceClock(seconds: 12)
                
                // Change possession
                self.possessingTeam = (kickingTeam == 0) ? 1 : 0
                
                // Handle touchback or normal return
                if finalYard >= 100 || finalYard <= 0 {
                    self.yardLine = (self.possessingTeam == 0) ? 20 : 80
                    self.appendLog("PUNT INTO THE END ZONE, TOUCHBACK. \(self.teams[self.possessingTeam]) TAKE OVER AT THE \(self.formattedYardLine).")
                } else {
                    self.yardLine = finalYard
                    self.appendLog("PUNT TRAVELED TO THE \(self.formattedYardLine). \(self.teams[self.possessingTeam]) TAKE OVER.")
                }
                
                self.down = 1
                self.yardsToGain = 10
                self.returnToPlaySelectionIfNeeded()
            }
        }
    }
    
    
    func executeFieldGoal() {
        // Special-Teams block check first
        if attemptSpecialTeamsBlock(isFieldGoal: true) {
            advanceClock(seconds: 8)
            return
        }

        let direction = possessingTeam == 0 ? 1 : -1
        let fieldGoalDistance = (possessingTeam == 0) ? (100 - yardLine + 17) : (yardLine + 17)
        
        appendLog("\(teams[possessingTeam]) ATTEMPTS A \(fieldGoalDistance)-YARD FIELD GOAL...")
        soundEngine.playWhistle()
        
        gamePhase = .animatingPlay
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            await self.graphicsEngine.playKickAnimation(
                startYardLine: self.yardLine,
                isFieldGoal: true,
                direction: direction
            ) { isGood, finalYard in
                
                self.advanceClock(seconds: 8)
                
                if isGood {
                    self.appendLog("FIELD GOAL IS GOOD! (+3 PTS)")
                    self.scores[self.possessingTeam] += 3
                    self.soundEngine.playTouchdownFanfare()
                    self.resetAfterScore()
                } else {
                    self.appendLog("FIELD GOAL MISSED!")
                    self.executeTurnover()
                }
            }
        }
    }
    
    func executeTurnover() {
        possessingTeam = (possessingTeam == 0) ? 1 : 0
        down = 1
        yardsToGain = 10
        returnToPlaySelectionIfNeeded()
    }
    
    private func resolveInterception(passDepth: Int, defRoster: TeamRoster) {
        soundEngine.playWhistle()
        
        let catchSpot = possessingTeam == 0 ? yardLine + passDepth : yardLine - passDepth
        
        if catchSpot >= 100 || catchSpot <= 0 {
            appendLog("INTERCEPTED!!!")
            appendLog("BY \(defRoster.def) IN THE ENDZONE...TOUCHBACK!")
            possessingTeam = (possessingTeam == 0) ? 1 : 0
            yardLine = (possessingTeam == 0) ? 20 : 80
            down = 1
            yardsToGain = 10
            returnToPlaySelectionIfNeeded()
            return
        }
        
        possessingTeam = (possessingTeam == 0) ? 1 : 0
        let returnYards = Int.random(in: 0...15)
        let returnedTo = possessingTeam == 0
            ? min(100, catchSpot + returnYards)
            : max(0, catchSpot - returnYards)
        
        appendLog("INTERCEPTED!!!")
        appendLog("BY \(defRoster.def)")
        
        if (possessingTeam == 0 && returnedTo >= 100) || (possessingTeam == 1 && returnedTo <= 0) {
            appendLog("RETURNED ALL THE WAY FOR A TOUCHDOWN! \(defRoster.def) SCORES! (+6 PTS)")
            yardLine = possessingTeam == 0 ? 100 : 0
            scores[possessingTeam] += 6
            soundEngine.playTouchdownFanfare()
            updateFieldGraphics()
            
            if possessingTeam == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.gamePhase = .extraPointSelection
                }
            } else {
                gamePhase = .extraPointSelection
                executeAIExtraPoint()
            }
            return
        }
        
        yardLine = returnedTo
        appendLog("RETURNED \(returnYards) YARDS TO THE \(formattedYardLine).")
        down = 1
        yardsToGain = 10
        returnToPlaySelectionIfNeeded()
    }
    
    func executePATKick() {
        selectPAT(isTwoPoint: false)
    }
    
    func executeTwoPointConversion() {
        selectPAT(isTwoPoint: true)
    }
    
    func selectPAT(isTwoPoint: Bool) {
        guard gamePhase == .extraPointSelection else { return }
        gamePhase = .animatingPlay
        
        let successChance = isTwoPoint ? 0.45 : 0.92
        if Double.random(in: 0...1) < successChance {
            let pts = isTwoPoint ? 2 : 1
            appendLog("PAT SUCCESSFUL! (+\(pts) PT)")
            scores[possessingTeam] += pts
            soundEngine.playTouchdownFanfare()
        } else {
            appendLog("PAT FAILED!")
        }
        resetAfterScore()
    }
    
    private func executeAIExtraPoint() {
        let trailingBy2 = (scores[0] - scores[1]) == 2
        let lateGameTwoPoint = quarter == 4 && timeRemaining < 300 && trailingBy2
        
        if lateGameTwoPoint {
            appendLog("\(teams[1]) GOES FOR 2-POINT CONVERSION...")
            selectPAT(isTwoPoint: true)
        } else {
            appendLog("\(teams[1]) LINING UP FOR EXTRA POINT...")
            selectPAT(isTwoPoint: false)
        }
    }
    
    private func resolvePlayResult(yardsGained: Int, offense: OffensePlay? = nil) {
        let tentativeYardLine = yardLine + (possessingTeam == 0 ? yardsGained : -yardsGained)
        let activeRoster = rosters[possessingTeam]
        
        if let offense = offense {
            let isPassPlay = offense == .shortPass || offense == .longPass
                || offense == .screenPass || offense == .playAction || offense == .trickPlay
            teamStats[possessingTeam].totalYards += yardsGained
            if isPassPlay {
                teamStats[possessingTeam].passYards += yardsGained
            } else {
                teamStats[possessingTeam].rushYards += yardsGained
            }
        }
        
        let isTouchdown = (possessingTeam == 0 && tentativeYardLine >= 100) || (possessingTeam == 1 && tentativeYardLine <= 0)
        let isSafety = (possessingTeam == 0 && tentativeYardLine <= 0) || (possessingTeam == 1 && tentativeYardLine >= 100)
        
        if isTouchdown {
            yardLine = possessingTeam == 0 ? 100 : 0
            if let offense = offense, offense == .shortPass || offense == .longPass || offense == .screenPass || offense == .playAction || offense == .trickPlay {
                appendLog("COMPLETE TO \(activeRoster.wr)")
                appendLog("IN THE ENDZONE...")
            }
            appendLog("TOUCHDOWN \(teams[possessingTeam])!!!!")
            scores[possessingTeam] += 6
            soundEngine.playTouchdownFanfare()
            updateFieldGraphics()
            
            if possessingTeam == 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    self?.gamePhase = .extraPointSelection
                }
            } else {
                gamePhase = .extraPointSelection
                executeAIExtraPoint()
            }
            return
        }
        
        if isSafety {
            yardLine = possessingTeam == 0 ? 0 : 100
            appendLog("\(activeRoster.qb) TACKLED IN THE ENDZONE")
            appendLog("SAFETY!!!")
            scores[(possessingTeam == 0) ? 1 : 0] += 2
            resetAfterScore()
            return
        }
        
        yardLine = tentativeYardLine
        
        if let offense = offense {
            let isPassPlay = offense == .shortPass || offense == .longPass
                || offense == .screenPass || offense == .playAction || offense == .trickPlay
            if isPassPlay && yardsGained > 0 {
                appendLog("COMPLETE TO \(activeRoster.wr)")
            }
        }
        
        if yardsGained > 0 {
            appendLog("\(randomTackleVerb()) \(formattedYardLinePhrase())")
            if yardsGained >= 5 && Bool.random() {
                appendLog("\(randomYACVerb())")
            }
            appendLog("GAIN OF \(yardsGained) YARDS.")
        } else if yardsGained < 0 {
            appendLog("\(randomTackleVerb()) \(formattedYardLinePhrase())")
            appendLog("STUFFED FOR A LOSS OF \(abs(yardsGained)) YARDS.")
        } else {
            appendLog("NO GAIN ON THE PLAY.")
        }
        
        if yardsGained >= yardsToGain {
            down = 1
            yardsToGain = 10
            teamStats[possessingTeam].firstDowns += 1
            appendLog("** FIRST DOWN \(teams[possessingTeam]) **")
            soundEngine.playWhistle()
        } else {
            down += 1
            yardsToGain -= yardsGained
            if down > 4 {
                appendLog("FOURTH DOWN--BALL GOES OVER")
                executeTurnover()
                return
            }
        }
        
        returnToPlaySelectionIfNeeded()
    }
    
    private func resetAfterScore() {
        possessingTeam = (possessingTeam == 0) ? 1 : 0
        yardLine = (possessingTeam == 0) ? 20 : 80
        down = 1
        yardsToGain = 10
        returnToPlaySelectionIfNeeded()
    }
    
    private func advanceClock(seconds: Int) {
        // Prevent negative clock
        timeRemaining = max(0, timeRemaining - seconds)
        
        if timeRemaining <= 0 {
            if quarter == 2 {
                quarter = 3
                timeRemaining = 900
                enterHalftime()
            } else if quarter < 4 {
                quarter += 1
                timeRemaining = 900
                appendLog("=== END OF QUARTER \(quarter - 1) ===")
                soundEngine.playWhistle()
            } else {
                // End of game
                buildFinalSummary()
                gamePhase = .gameOver
                appendLog("=== GAME OVER ===")
                appendLog("FINAL SCORE: \(teams[0]) \(scores[0]) - \(teams[1]) \(scores[1])")
                soundEngine.playWhistle()
            }
        }
    }
    
    private func buildFinalSummary() {
        var lines: [String] = []
        
        lines.append("========== FINAL ==========")
        lines.append("\(teams[0])  \(scores[0])")
        lines.append("\(teams[1])  \(scores[1])")
        lines.append("")
        lines.append("── TEAM STATISTICS ──")
        
        for i in 0..<2 {
            let s = teamStats[i]
            lines.append("\(teams[i])")
            lines.append("  First Downs: \(s.firstDowns)")
            lines.append("  Total Yards: \(s.totalYards)")
            lines.append("  Rushing:     \(s.rushYards)")
            lines.append("  Passing:     \(s.passYards)")
            lines.append("  Turnovers:   \(s.turnovers)")
            if i == 0 { lines.append("") }
        }
        
        finalSummaryLines = lines
    }
    
    private func enterHalftime() {
        gamePhase = .halftime
        halftimeShow.begin(teams: teams, marchingBandTeam: teams[1], stats: teamStats) { [weak self] in
            self?.resumeSecondHalf()
        }
    }
    
    private func resumeSecondHalf() {
        appendLog("IT'S THE SECOND HALF!")
        possessingTeam = (possessingTeam == 0) ? 1 : 0
        yardLine = (possessingTeam == 0) ? 20 : 80
        down = 1
        yardsToGain = 10
        soundEngine.playWhistle()
        gamePhase = .playSelection
        updateFieldGraphics()
    }
    
    // MARK: - Play-by-Play Helpers
    
    private func randomBreakFromHuddle() -> String {
        [" BREAK FROM THE HUDDLE", " COME TO THE LINE"].randomElement()!
    }
    
    private func randomSignals() -> String {
        [" CALLS", " BARKS"].randomElement()!
    }
    
    private func randomSnap() -> String {
        ["SNAP", "PLAY"].randomElement()!
    }
    
    private func randomDropBack() -> String {
        ["DROPS", "FADES"].randomElement()!
    }
    
    private func randomPressure() -> String {
        ["GETTING A HARD RUSH", "BEING PRESSURED"].randomElement()!
    }
    
    private func randomTackleVerb() -> String {
        ["TACKLED", "HIT", "DROPPED", "STOPPED", "HIT AND HIT HARD",
         "TRIPPED UP", "CREAMED", "LEVELED", "SHOVED OUT OF BOUNDS",
         "KNOCKED OUT OF BOUNDS"].randomElement()!
    }
    
    private func randomYACVerb() -> String {
        ["MAKES A MOVE", "BREAKS A TACKLE", "STUMBLES", "STIFFARMS A TACKLER"].randomElement()!
    }
    
    private func randomSide() -> String {
        Bool.random() ? "LEFT" : "RIGHT"
    }
    
    private func formattedYardLinePhrase() -> String {
        if yardLine == 50 {
            return "AT THE 50"
        }
        let cl = yardLine > 50 ? 100 - yardLine : yardLine
        if abs(50 - yardLine) > 9 {
            return "AT THE \(cl)"
        }
        let city = possessingTeam == 0 ? teams[0] : teams[1]
        return "AT THE \(city) \(cl)"
    }
    
    private func describePlayCall(offense: OffensePlay, qb: String, rb: String, wr: String) {
        switch offense {
        case .runInside:
            if Bool.random() {
                appendLog("\(qb) KEEPS IT")
            } else {
                appendLog("\(qb) GIVES TO \(rb)")
                appendLog("UP THE MIDDLE")
            }
        case .runOutside:
            appendLog("\(qb) GIVES TO \(rb)")
            appendLog("OFF \(randomSide()) TACKLE")
        case .pitch:
            appendLog("\(qb) QUICK PITCH TO")
            appendLog("\(rb) SWEEPING \(randomSide())")
        case .shortPass, .longPass, .screenPass, .playAction:
            break
        case .trickPlay:
            let chainCount = Int.random(in: 2...4)
            var current = qb
            for _ in 0..<chainCount {
                let next = [rb, wr].randomElement()!
                if next == current { continue }
                appendLog("\(current)\([" PITCHES", " HANDS OFF", " LATERALS"].randomElement()!) TO \(next)")
                current = next
            }
            if Bool.random() {
                appendLog("\(current) TRYING TO THROW LONG...")
            } else {
                appendLog("\(current)'S GOING TO RUN...")
            }
        default:
            break
        }
    }
}
