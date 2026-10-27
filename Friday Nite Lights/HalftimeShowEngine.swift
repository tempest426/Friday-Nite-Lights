import Foundation
import Combine
import Darwin

struct TeamStats {
    var firstDowns: Int = 0
    var totalYards: Int = 0
    var rushYards: Int = 0
    var passYards: Int = 0
    var turnovers: Int = 0
}

@MainActor
final class HalftimeShowEngine: ObservableObject {
    enum Stage {
        case hidden
        case stats
        case dotsShow
    }
    
    @Published private(set) var stage: Stage = .hidden
    @Published private(set) var statLines: [String] = []
    @Published private(set) var presentingLines: [String] = []
    
    private let graphicsEngine: AppleIIGraphicsEngine
    private let soundEngine: AppleIISoundEngine
    
    private var showAnimationTask: Task<Void, Never>?
    private var audioScoreTask: Task<Void, Never>?
    private var onConcluded: (() -> Void)?
    private var marchingBandTeam: String = ""
    
    init(graphicsEngine: AppleIIGraphicsEngine, soundEngine: AppleIISoundEngine) {
        self.graphicsEngine = graphicsEngine
        self.soundEngine = soundEngine
    }
    
    func begin(teams: [String], marchingBandTeam: String, stats: [TeamStats], onConcluded: @escaping () -> Void) {
        self.onConcluded = onConcluded
        self.marchingBandTeam = marchingBandTeam
        soundEngine.playWhistle()
        
        var lines = ["--> HALFTIME STATS <--"]
        for (index, team) in teams.enumerated() {
            let s = stats[index]
            lines.append("\(team): \(s.firstDowns) FIRST DOWNS, \(s.totalYards) TOTAL YDS (\(s.rushYards) RUSH / \(s.passYards) PASS), \(s.turnovers) TURNOVERS")
        }
        statLines = lines
        stage = .stats
    }
    
    func proceedToShow() {
        guard stage == .stats else { return }
        stage = .dotsShow
        presentingLines = ["PRESENTING...", "THE UNIVERSITY OF \(marchingBandTeam) MARCHING DOTS"]
        startMarchingDotsAnimation()
    }
    
    func conclude() {
        guard stage == .dotsShow else { return }
        stopMarchingDotsAnimation()
        stage = .hidden
        statLines = []
        presentingLines = []
        let callback = onConcluded
        onConcluded = nil
        callback?()
    }
    
    private func startMarchingDotsAnimation() {
        stopMarchingDotsAnimation()
        // Clearing is buffer-only now, so each intended blank screen is committed.
        graphicsEngine.clear(color: 12) // light green field background
        graphicsEngine.commitFrame()

        audioScoreTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                await self.soundEngine.playScore(
                    StarsAndStripesSong.loopBody,
                    bpm: 240.0,
                    instrument: .melodic
                )
            }
        }
        
        // 2. Animation Task
        showAnimationTask = Task { @MainActor in
            graphicsEngine.clear(color: 12) // light green field background
            graphicsEngine.commitFrame()
            
            while !Task.isCancelled && stage == .dotsShow {
                await runAct1_SpiralDrill()
                guard !Task.isCancelled && stage == .dotsShow else { break }
                
                graphicsEngine.clear(color: 12) // light green field background
                graphicsEngine.commitFrame()
            }
        }
    }
    
    private func stopMarchingDotsAnimation() {
        audioScoreTask?.cancel()
        audioScoreTask = nil
        
        showAnimationTask?.cancel()
        showAnimationTask = nil
    }
    
    // MARK: - Frame Scripted Drill Book

    private struct BandDot { var x: Double; var y: Double; var color: UInt8 = 15 }

    private func drawBand(_ dots:[BandDot]) {
        graphicsEngine.clear(color: 12) // solid light green field, no yard markings during the show
        for d in dots {
            graphicsEngine.setPixel(x: Int(d.x.rounded()), y: Int(d.y.rounded()), color: d.color)
        }
        graphicsEngine.commitFrame()
    }

    private func interpolate(_ a:[BandDot], _ b:[BandDot], t:Double) -> [BandDot] {
        zip(a,b).map { BandDot(x:$0.x+($1.x-$0.x)*t, y:$0.y+($1.y-$0.y)*t, color:$0.color) }
    }

    private func animate(to target:[BandDot], from current: inout [BandDot], frames:Int, delay:UInt64) async {
        let start=current
        for f in 1...frames {
            guard stage == .dotsShow && !Task.isCancelled else { return }
            current=interpolate(start,target,t:Double(f)/Double(frames))
            drawBand(current)
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private var scaleX: Double { Double(AppleIIGraphicsEngine.width) / 80.0 }
    private var scaleY: Double { Double(AppleIIGraphicsEngine.height) / 48.0 }

    private func textFormation(_ text:String, count:Int) -> [BandDot] {
        let glyphs:[Character:[String]]=[
            "L":["X....","X....","X....","X....","XXXXX"],
            "E":["XXXXX","X....","XXXX.","X....","XXXXX"],
            "T":["XXXXX","..X..","..X..","..X..","..X.."],
            "S":[".XXX.","X....",".XX..","...X.","XXX.."],
            "G":[".XXX.","X....","X.XX.","X..X.",".XXX."],
            "O":[".XXX.","X...X","X...X","X...X",".XXX."],
            "B":["XXXX.","X...X","XXXX.","X...X","XXXX."],
            "U":["X...X","X...X","X...X","X...X",".XXX."],
            "F":["XXXXX","X....","XXXX.","X....","X...."],
            "A":[".XXX.","X...X","XXXXX","X...X","X...X"]
        ]

        let leftBound = 4.0
        let rightBound = 76.0
        let availableWidth = rightBound - leftBound

        var raw:[(x:Double,y:Double)]=[]
        var x=0.0
        for ch in text where ch != "'" {
            if ch==" " { x+=4; continue }
            guard let g=glyphs[ch] else { continue }
            for (r,row) in g.enumerated() {
                for (c,v) in row.enumerated() where v=="X" {
                    raw.append((x:x+Double(c)*2,y:14+Double(r)*3))
                }
            }
            x+=12
        }
        let naturalWidth = raw.map { $0.x }.max() ?? 0
        let fitScale = naturalWidth > availableWidth ? availableWidth/naturalWidth : 1.0

        var pts:[BandDot] = raw.map {
            let baselineX = leftBound + $0.x*fitScale
            return BandDot(x: baselineX*scaleX, y: $0.y*scaleY)
        }
        while pts.count<count { pts.append(pts[pts.count % max(1,pts.count)]) }
        return Array(pts.prefix(count))
    }
    
    private func runAct1_SpiralDrill() async {
        var band:[BandDot]=[]
        for r in 0..<12 {
            for c in 0..<12 {
                band.append(BandDot(x:(4.0+Double(c))*scaleX, y:(6.0+Double(r)*3)*scaleY))
                band.append(BandDot(x:(76.0-Double(c))*scaleX, y:(6.0+Double(r)*3)*scaleY))
                if band.count>=144 { break }
            }
            if band.count>=144 { break }
        }
        drawBand(band)

        var company=band
        for i in 0..<company.count {
            company[i].x = i<72 ? (28.0+Double(i%6)*2.5)*scaleX : (52.0-Double(i%6)*2.5)*scaleX
        }
        await animate(to: company, from: &band, frames:120, delay:83_000_000)

        var twirl=band
        let cx=40.0*scaleX, cy=24.0*scaleY
        let ringScale = min(scaleX, scaleY)
        for i in 0..<twirl.count {
            let ring=(6.0+Double(i%10))*ringScale
            let ang=Double(i)/6.0
            twirl[i].x=cx+cos(ang)*ring
            twirl[i].y=cy+sin(ang)*ring
        }
        await animate(to: twirl, from: &band, frames:90, delay:83_000_000)

        var square=band
        let sideX=24.0*scaleX, sideY=24.0*scaleY
        for i in 0..<square.count {
            let p=Double(i)/Double(square.count)*4
            if p<1 { square[i].x=cx-sideX/2+p*sideX; square[i].y=cy-sideY/2 }
            else if p<2 { square[i].x=cx+sideX/2; square[i].y=cy-sideY/2+(p-1)*sideY }
            else if p<3 { square[i].x=cx+sideX/2-(p-2)*sideX; square[i].y=cy+sideY/2 }
            else { square[i].x=cx-sideX/2; square[i].y=cy+sideY/2-(p-3)*sideY }
        }
        await animate(to: square, from: &band, frames:90, delay:83_000_000)

        let lets=textFormation("LET'S GO", count: band.count)
        await animate(to: lets, from: &band, frames:90, delay:83_000_000)
        try? await Task.sleep(nanoseconds:2_000_000_000)

        let buffalo=textFormation("BUFFALO", count: band.count)
        await animate(to: buffalo, from: &band, frames:90, delay:83_000_000)
        try? await Task.sleep(nanoseconds:2_000_000_000)

        var exit=band
        for i in 0..<exit.count { exit[i].x = i<72 ? 4.0*scaleX : 76.0*scaleX }
        await animate(to: exit, from: &band, frames:60, delay:83_000_000)
        graphicsEngine.clear(color:12) // light green field background
        graphicsEngine.commitFrame()
    }

    deinit {
        audioScoreTask?.cancel()
        showAnimationTask?.cancel()
    }
}
