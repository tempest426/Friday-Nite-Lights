import SwiftUI

struct ContentView: View {
    @StateObject private var game = FootballGameEngine()
    
    var body: some View {
        VStack(spacing: 12) {
            // Retro Header Scoreboard with Possession Indicator & Debug Controls
            ZStack(alignment: .topTrailing) {
                ScoreboardView(game: game)
                
            }
            
            // Pixel Canvas View with Dynamic Field & Coin Overlay Animation
            ZStack {
                GraphicsCanvasView(graphics: game.graphicsEngine)
                
                if game.isFlippingCoin {
                    VStack {
                        Text(game.coinFlipDisplay)
                            .font(.system(.title2, design: .monospaced).bold())
                            .foregroundColor(.yellow)
                            .padding(8)
                            .background(Color.black.opacity(0.8))
                            .border(Color.yellow, width: 2)
                            .offset(y: game.coinYOffset)
                    }
                }
            }
            
            // Retro Console Log Output
            ConsoleLogView(game: game)
            
            // Interactive Play Calling Panel
            ControlPanelView(game: game)
        }
        .padding()
        .background(Color.black.ignoresSafeArea())
    }
    
}

// MARK: - Scoreboard

private struct ScoreboardView: View {
    @ObservedObject var game: FootballGameEngine
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text("\(game.teams[0]): \(game.scores[0])")
                    if game.possessingTeam == 0 {
                        Text("<").foregroundColor(.yellow)
                    }
                }
                .foregroundColor(.blue)
                
                HStack(spacing: 4) {
                    Text("\(game.teams[1]): \(game.scores[1])")
                    if game.possessingTeam == 1 {
                        Text("<").foregroundColor(.yellow)
                    }
                }
                .foregroundColor(Color(red: 227/255, green: 24/255, blue: 55/255))
            }
            Spacer()
            VStack {
                Text("QTR: \(game.quarter)")
                Text("TIME: \(game.formattedClock)")
            }
            .foregroundColor(.green)
            Spacer()
            VStack(alignment: .trailing) {
                if game.isGoalToGo {
                    Text("DOWN: \(game.down)  AND GOAL")
                } else {
                    Text("DOWN: \(game.down)  DIST: \(game.yardsToGain)")
                }
                Text("BALL ON: \(game.formattedYardLine)")
            }
            .foregroundColor(.green)
        }
        .font(.system(.body, design: .monospaced).bold())
        .padding(8)
        .border(Color.green, width: 2)
    }
}

// MARK: - Graphics Canvas

private struct GraphicsCanvasView: View {
    @ObservedObject var graphics: AppleIIGraphicsEngine
    
    var body: some View {
        Group {
            // The engine already builds `currentFrame` as a CGImage every
            // update; drawing that directly is a single GPU-blitted image
            // instead of the 15,360 individual Canvas fill() calls a
            // per-pixel loop would require every frame.
            if let cgImage = graphics.currentFrame {
                Image(decorative: cgImage, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none) // preserve crisp, blocky Apple II pixels
            } else {
                // Before the first frame has been published.
                Color.black
            }
        }
        .frame(width: 480, height: 288)
        .border(Color.green, width: 2)
        .background(Color.black)
    }
}

// MARK: - Console Log

private struct ConsoleLogView: View {
    @ObservedObject var game: FootballGameEngine
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(game.logOutput.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(height: 120)
            .border(Color.green, width: 2)
            .background(Color.black)
            .onChange(of: game.logOutput.count) { _ in
                if !game.logOutput.isEmpty {
                    proxy.scrollTo(game.logOutput.count - 1, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Control Panel

private struct ControlPanelView: View {
    @ObservedObject var game: FootballGameEngine
    
    var body: some View {
        VStack(spacing: 8) {
            switch game.gamePhase {
            case .introTitle, .coinToss:
                if game.isFlippingCoin {
                    Text("FLIPPING COIN...")
                        .font(.system(.body, design: .monospaced).bold())
                        .foregroundColor(.yellow)
                } else {
                    Button("START COIN TOSS") {
                        game.triggerCoinToss()
                    }
                    .buttonStyle(RetroButtonStyle())
                }
                
            case .playSelection:
                if game.possessingTeam == 0 {
                    // Full Offensive Play Calling Grid
                    Text("OFFENSE: SELECT PLAY")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(.green)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(game.offensivePlays) { play in
                            Button {
                                game.selectOffensivePlay(play)
                            } label: {
                                Text(play.name)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .multilineTextAlignment(.center)
                            }
                            .buttonStyle(RetroButtonStyle())
                        }
                    }
                } else {
                    // Full Defensive Alignments
                    Text("DEFENSE: SELECT ALIGNMENT")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(.orange)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(game.defensivePlays) { scheme in
                            Button {
                                game.selectDefensivePlay(scheme)
                            } label: {
                                Text(scheme.name)
                                    .frame(maxWidth: .infinity, minHeight: 36)
                                    .multilineTextAlignment(.center)
                            }
                            .buttonStyle(RetroButtonStyle())
                        }
                    }
                }
                
            case .extraPointSelection:
                HStack(spacing: 16) {
                    Button("PAT KICK (1 PT)") {
                        game.executePATKick()
                    }
                    .buttonStyle(RetroButtonStyle())
                    
                    Button("2-PT CONVERSION") {
                        game.executeTwoPointConversion()
                    }
                    .buttonStyle(RetroButtonStyle())
                }
                
            case .halftime:
                HalftimeControlView(halftime: game.halftimeShow)
                
            case .animatingPlay:
                Text("EXECUTING PLAY...")
                    .font(.system(.body, design: .monospaced).bold())
                    .foregroundColor(.yellow)
                
            case .gameOver:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(game.finalSummaryLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    
                    Button("RESTART GAME") {
                        game.startOpeningSequence()
                    }
                    .buttonStyle(RetroButtonStyle())
                    .padding(.top, 8)
                }
            }
        }
        .frame(height: 140)
    }
}

// MARK: - Halftime

private struct HalftimeControlView: View {
    @ObservedObject var halftime: HalftimeShowEngine
    
    var body: some View {
        switch halftime.stage {
        case .stats:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(halftime.statLines, id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.green)
                }
                Button("CONTINUE") {
                    halftime.proceedToShow()
                }
                .buttonStyle(RetroButtonStyle())
            }
         
            
        case .dotsShow:
            VStack(spacing: 6) {
                ForEach(halftime.presentingLines, id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(.yellow)
                }
                Button("PRESS TO CONCLUDE HALFTIME") {
                    halftime.conclude()
                }
                .buttonStyle(RetroButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
            }
            
        case .hidden:
            EmptyView()
        }
    }
}

// MARK: - Retro Button Styles

struct RetroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .monospaced).bold())
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(configuration.isPressed ? Color.green : Color.black)
            .foregroundColor(configuration.isPressed ? Color.black : Color.green)
            .border(Color.green, width: 2)
    }
}

struct RetroDebugButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption2, design: .monospaced).bold())
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(configuration.isPressed ? Color.yellow : Color.black)
            .foregroundColor(configuration.isPressed ? Color.black : Color.yellow)
            .border(Color.yellow, width: 1)
    }
}
