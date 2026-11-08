import Foundation
import SwiftUI
import AppKit

/// The result of a kick play, fully decided by the game engine.
///
/// The graphics engine animates whatever this describes: it never rolls for a make or a
/// miss, never picks a landing spot and never decides who takes over. Keeping the result
/// here means game balance stays in the game engine and the animation is a function of
/// the outcome plus cosmetic randomness (apex height, drift, the roll after landing).
enum KickOutcome: Equatable {
    /// Field goal attempt, and how it resolved.
    case fieldGoal(FieldGoalResult)
    
    /// Punt that came down in the field of play, or went into the end zone as a touchback.
    /// `spotYardLine` is where the ball is placed (absolute 0...100); for a touchback that
    /// is the receiving team's own 20, while the ball is drawn flying into the end zone.
    case punt(spotYardLine: Int, isTouchback: Bool)
    
    /// Kickoff, with the same landing semantics as a punt.
    case kickoff(spotYardLine: Int, isTouchback: Bool)
    
    enum FieldGoalResult: Equatable {
        case good
        case wideLeft
        case wideRight
        case short
    }
    
    /// Where the ball is spotted after a punt or kickoff (nil for a field goal).
    var spotYardLine: Int? {
        switch self {
        case .punt(let spot, _), .kickoff(let spot, _): return spot
        case .fieldGoal: return nil
        }
    }
    
    /// True when a punt or kickoff went into the end zone.
    var isTouchback: Bool {
        switch self {
        case .punt(_, let touchback), .kickoff(_, let touchback): return touchback
        case .fieldGoal: return false
        }
    }
}

/// Apple II low-resolution rasteriser (160×96, indexed 16-colour palette).
///
/// Frame contract: every drawing method (`clear`, `setPixel`, `drawField` and the
/// animations' frame renderers) only mutates `pixelBuffer`. Nothing becomes a visible
/// frame until `commitFrame()` is called, so a caller that draws several primitives
/// composes the whole frame first and commits once.
@MainActor
class AppleIIGraphicsEngine: ObservableObject {
    static let width = 160
    static let height = 96
    static let totalPixels = width * height
    
    /// The playing field is 112 px wide between the goal lines, and that width spans
    /// 100 yards. Every yard-based offset (ball carrier, kick travel) converts at this
    /// rate, so callers can pass yards and get pixels that line up with the field.
    private static let fieldWidthPixels = 112.0
    private static let pxPerYard = fieldWidthPixels / 100.0
    
    // Output image for SwiftUI view (zero-cost UI redrawing). Written only by
    // commitFrame(), so views can never publish a frame the engine didn't build.
    @Published private(set) var currentFrame: CGImage?
    
    // Raw pixel buffer. Readable by collaborators, mutable only through the drawing
    // API; direct writes would bypass commitFrame() and leave the UI stale.
    private(set) var pixelBuffer = [UInt8](repeating: 0, count: totalPixels)
    
    // Pre-baked static field background buffer
    private var staticFieldBuffer = [UInt8](repeating: 0, count: totalPixels)
    
    // Cached splash buffer
    private var cachedSplashBuffer: [UInt8]?
    
    // Reused every frame by updateFrameImage() instead of allocating a
    // fresh [UInt32] on every call (this runs at up to ~30fps during play
    // animation and the halftime show).
    private var rgbaScratch = [UInt32](repeating: 0, count: totalPixels)
    
    // Color Palette (Apple II 16-color)
    let colorPalette: [Color] = [
        .black, .purple, Color(red: 0/255, green: 51/255, blue: 141/255), .purple,
        .mint, .gray, .blue, .cyan,
        .orange, .orange, .gray, .pink,
        .green, .yellow, .cyan, .white, Color(red: 227/255, green: 24/255, blue: 55/255)
    ]
    
    // Pre-converted RGBA 32-bit palette for instant CGImage generation
    private lazy var rgbaPalette: [UInt32] = {
        colorPalette.map { color in
            let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
            let r = UInt32(nsColor.redComponent * 255.0)
            let g = UInt32(nsColor.greenComponent * 255.0)
            let b = UInt32(nsColor.blueComponent * 255.0)
            let a = UInt32(255)
            // ABGR / RGBA layout depending on endianness
            return (a << 24) | (b << 16) | (g << 8) | r
        }
    }()
    
    private lazy var nsColorPalette: [(r: Float, g: Float, b: Float)] = {
        colorPalette.map { color in
            let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
            return (
                Float(nsColor.redComponent),
                Float(nsColor.greenComponent),
                Float(nsColor.blueComponent)
            )
        }
    }()
    
    init() {
        bakeStaticField()
    }
    
    // MARK: - Fast CGImage Renderer
    
    /// Converts the current pixel buffer into a CGImage and publishes it to the UI.
    /// This is the only way a drawn frame reaches the screen.
    func commitFrame() {
        updateFrameImage()
    }
    
    // MARK: - Animation Lifetime
    
    /// Identifies the newest animation. A loop that finds it has been superseded stops
    /// writing frames, so two animations can never interleave on the same buffer.
    private var animationGeneration = 0
    
    /// Marks the start of a new animation, superseding any older one.
    private func beginAnimation() -> Int {
        animationGeneration &+= 1
        return animationGeneration
    }
    
    /// True while `generation` is still the animation allowed to draw.
    private func isCurrent(_ generation: Int) -> Bool {
        generation == animationGeneration && !Task.isCancelled
    }
    
    /// Sleeps on the main actor, reporting whether the animation may continue. A cancelled
    /// task throws out of `Task.sleep` immediately, so cancellation unwinds the animation
    /// instead of being swallowed and played to the end.
    private func pause(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }
        return !Task.isCancelled
    }
    
    /// Converts raw Apple II palette buffer to CGImage in microsecond time
    private func updateFrameImage() {
        // Fill the reused scratch buffer in place rather than allocating a
        // new [UInt32] every frame.
        rgbaScratch.withUnsafeMutableBufferPointer { dest in
            guard let dest = dest.baseAddress else { return }
            for i in 0..<AppleIIGraphicsEngine.totalPixels {
                let colorIdx = Int(pixelBuffer[i])
                dest[i] = rgbaPalette[colorIdx < rgbaPalette.count ? colorIdx : 0]
            }
        }
        
        // CGImage needs its own independent copy of the pixel data (since
        // rgbaScratch will be overwritten next frame), so this Data copy is
        // still required for correctness — only the source-side allocation
        // above is what's being saved per frame.
        let data = Data(bytes: rgbaScratch, count: rgbaScratch.count * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        
        if let cgImage = CGImage(
            width: AppleIIGraphicsEngine.width,
            height: AppleIIGraphicsEngine.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: AppleIIGraphicsEngine.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) {
            self.currentFrame = cgImage
        }
    }
    
    @inline(__always)
    func clear(color: UInt8 = 0) {
        pixelBuffer.withUnsafeMutableBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            memset(baseAddress, Int32(color), AppleIIGraphicsEngine.totalPixels)
        }
    }
    
    @inline(__always)
    func setPixel(x: Int, y: Int, color: UInt8) {
        guard x >= 0 && x < AppleIIGraphicsEngine.width && y >= 0 && y < AppleIIGraphicsEngine.height else { return }
        pixelBuffer[y * AppleIIGraphicsEngine.width + x] = color
    }

    // MARK: - Static Field Pre-Baking
    
    private func bakeStaticField() {
        let width = AppleIIGraphicsEngine.width
        let marginTop = 8
        let marginBottom = 88
        let fieldLeft = 8
        let fieldRight = 152
        let endzoneWidth = 16
        let fieldStartX = 24
        let fieldWidthPixels = 112.0
        
        staticFieldBuffer.withUnsafeMutableBufferPointer { ptr in
            guard let buf = ptr.baseAddress else { return }
            memset(buf, 0, AppleIIGraphicsEngine.totalPixels)
            
            // 1. Field Green
            let fieldFillWidth = fieldRight - fieldLeft
            for y in marginTop..<marginBottom {
                memset(buf + (y * width + fieldLeft), 4, fieldFillWidth)
            }
            
            // 2. Endzones
            for y in marginTop..<marginBottom {
                let rowOffset = y * width
                memset(buf + (rowOffset + fieldLeft), 16, endzoneWidth) // Red
                memset(buf + (rowOffset + fieldRight - endzoneWidth), 2, endzoneWidth) // Blue
            }
            
            // 3. Yard Lines
            for yard in stride(from: 10, through: 90, by: 10) {
                let x = fieldStartX + Int((Double(yard) / 100.0) * fieldWidthPixels)
                for y in marginTop..<marginBottom {
                    buf[y * width + x] = 15 // White
                }
            }

            // 4. Goal posts at the back of both end zones (always visible)
            bakeGoalPosts(into: buf, baseX: AppleIIGraphicsEngine.goalPostLeftX, lean: 1)
            bakeGoalPosts(into: buf, baseX: AppleIIGraphicsEngine.goalPostRightX, lean: -1)
        }
    }

    // MARK: - Image Asset Loading & Color Palette Quantization

    private func nearestPaletteIndex(r: Float, g: Float, b: Float) -> UInt8 {
        var minDistance = Float.greatestFiniteMagnitude
        var closestIndex: UInt8 = 0
        
        for (index, pal) in nsColorPalette.enumerated() {
            let dr = r - pal.r
            let dg = g - pal.g
            let db = b - pal.b
            let distance = dr * dr + dg * dg + db * db
            
            if distance < minDistance {
                minDistance = distance
                closestIndex = UInt8(index)
            }
        }
        
        return closestIndex
    }
    
    private func getOrLoadSplashBuffer() -> [UInt8] {
        if let existing = cachedSplashBuffer {
            return existing
        }
        
        var buffer = Array(repeating: UInt8(0), count: AppleIIGraphicsEngine.totalPixels)
        guard let image = NSImage(named: "FridayNiteLightsSplash") else { return buffer }
        
        let targetWidth = AppleIIGraphicsEngine.width
        let targetHeight = AppleIIGraphicsEngine.height
        var imageRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        
        guard let cgImage = image.cgImage(forProposedRect: &imageRect, context: nil, hints: nil) else {
            return buffer
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var rawData = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        
        guard let context = CGContext(
            data: &rawData,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return buffer
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        let inv255: Float = 1.0 / 255.0
        for y in 0..<targetHeight {
            let rowOffset = y * targetWidth
            for x in 0..<targetWidth {
                let offset = (rowOffset + x) * 4
                let r = Float(rawData[offset]) * inv255
                let g = Float(rawData[offset + 1]) * inv255
                let b = Float(rawData[offset + 2]) * inv255
                buffer[rowOffset + x] = nearestPaletteIndex(r: r, g: g, b: b)
            }
        }
        
        cachedSplashBuffer = buffer
        return buffer
    }
    
    // MARK: - Scaled Splash Drawing

    private func drawScaledSplash(scale: Double, sourceBuffer: [UInt8]) {
        let clampedScale = max(0.05, min(1.0, scale))
        let fullWidth = AppleIIGraphicsEngine.width
        let fullHeight = AppleIIGraphicsEngine.height
        
        let scaledWidth = Int(Double(fullWidth) * clampedScale)
        let scaledHeight = Int(Double(fullHeight) * clampedScale)
        
        guard scaledWidth > 0 && scaledHeight > 0 else { return }
        
        let startX = (fullWidth - scaledWidth) / 2
        let startY = (fullHeight - scaledHeight) / 2
        
        let stepY = Double(fullHeight) / Double(scaledHeight)
        let stepX = Double(fullWidth) / Double(scaledWidth)
        
        pixelBuffer.withUnsafeMutableBufferPointer { destPtr in
            guard let dest = destPtr.baseAddress else { return }
            memset(dest, 0, AppleIIGraphicsEngine.totalPixels)
            
            sourceBuffer.withUnsafeBufferPointer { srcPtr in
                guard let src = srcPtr.baseAddress else { return }
                
                for sy in 0..<scaledHeight {
                    let targetY = startY + sy
                    guard targetY >= 0 && targetY < fullHeight else { continue }
                    
                    let srcY = min(Int(Double(sy) * stepY), fullHeight - 1)
                    let srcRowOffset = srcY * fullWidth
                    let targetRowOffset = targetY * fullWidth
                    
                    for sx in 0..<scaledWidth {
                        let targetX = startX + sx
                        guard targetX >= 0 && targetX < fullWidth else { continue }
                        
                        let srcX = min(Int(Double(sx) * stepX), fullWidth - 1)
                        dest[targetRowOffset + targetX] = src[srcRowOffset + srcX]
                    }
                }
            }
        }
    }
    
    // MARK: - Jumbotron Startup Animation Sequence

    /// Animates the jumbotron splash in from the centre of the screen.
    /// - Returns: true if the animation played to the end; false if it was cancelled or
    ///   superseded by a newer animation.
    @discardableResult
    func playStartupAnimation() async -> Bool {
        let generation = beginAnimation()
        let splashBuffer = getOrLoadSplashBuffer()
        
        clear(color: 0)
        commitFrame()
        guard await pause(nanoseconds: 100_000_000) else { return false }
        
        let totalFrames = 20
        for frame in 1...totalFrames {
            guard isCurrent(generation) else { return false }
            let progress = Double(frame) / Double(totalFrames)
            let easeOutProgress = 1.0 - pow(1.0 - progress, 2)
            let currentScale = 0.05 + (0.95 * easeOutProgress)
            
            drawScaledSplash(scale: currentScale, sourceBuffer: splashBuffer)
            commitFrame()
            guard await pause(nanoseconds: 20_000_000) else { return false }
        }
        
        drawScaledSplash(scale: 1.0, sourceBuffer: splashBuffer)
        commitFrame()
        return true
    }
    
    // MARK: - Intro Splash

    func drawIntroSplash(showTitleCard: Bool) {
        guard showTitleCard else { return }
        
        let width = AppleIIGraphicsEngine.width
        let height = AppleIIGraphicsEngine.height
        
        pixelBuffer.withUnsafeMutableBufferPointer { ptr in
            guard let buf = ptr.baseAddress else { return }
            memset(buf, 0, AppleIIGraphicsEngine.totalPixels)
            
            let bottomRowOffset = (height - 1) * width
            memset(buf, 12, width)
            memset(buf + bottomRowOffset, 12, width)
            
            for y in 0..<height {
                let rowOffset = y * width
                buf[rowOffset] = 12
                buf[rowOffset + width - 1] = 12
            }
        }
    }
    
    // MARK: - Kick / Punt / Kickoff / Field Goal Animation (top-down view)

    /// Lateral (screen Y) centre of the field and half-width of the uprights, in pixels.
    private static let kickCenterLat = 48.0
    private static let goalHalfGap = 6.0

    /// Goal posts stand at the back of each end zone. X is the base of the posts; heights are
    /// in the same "pixels up the screen" units the kick animation uses for ball height.
    private static let goalPostLeftX = 9
    private static let goalPostRightX = 150
    private static let goalCrossbarHeight = 4.0
    private static let goalUprightHeight = 16.0

    /// Animates a kick play that the game engine has already resolved.
    ///
    /// The engine only draws: whether the kick is good, wide, short, where it lands and
    /// who takes over are game decisions, handed in as `outcome`. This method turns that
    /// result into a trajectory and plays it; only the cosmetic side of the flight (hang
    /// time, apex, lateral drift, the roll after the ball comes down) is decided here.
    ///
    /// The field is viewed from above, so screen X is downfield, screen Y is lateral,
    /// and altitude is shown by drawing a shadow on the ground track and lifting the
    /// ball sprite straight up the screen by its height.
    ///
    /// - Parameters:
    ///   - outcome: what happened on the kick, including how a miss missed.
    ///   - startYardLine: Kicker's yard line (0–100, same scale as `drawField`)
    ///   - direction: +1 (kicking toward yard 100) or -1 (kicking toward yard 0)
    /// - Returns: true if the animation played to the end; false if it was cancelled or
    ///   superseded by a newer animation, in which case the caller must not act on it.
    @discardableResult
    func playKick(
        _ outcome: KickOutcome,
        startYardLine: Int,
        direction: Int
    ) async -> Bool {
        let generation = beginAnimation()
        let dir = direction >= 0 ? 1 : -1
        let dirD = Double(dir)
        let fieldStartX = 24.0
        let pxPerYard = AppleIIGraphicsEngine.pxPerYard
        let centerLat = AppleIIGraphicsEngine.kickCenterLat
        let halfGap = AppleIIGraphicsEngine.goalHalfGap
        let startX = fieldStartX + Double(startYardLine) * pxPerYard
        // Posts stand at the back of each end zone, expressed in yards downfield, and a kick
        // that reaches them crosses their plane at this fraction of its flight.
        let postX = Double(dir > 0 ? AppleIIGraphicsEngine.goalPostRightX : AppleIIGraphicsEngine.goalPostLeftX)
        let postYard = (postX - fieldStartX) / pxPerYard
        let goalPlaneFraction = 0.93

        // 1. Draw the static backdrop once, then snapshot it. Every frame starts from this
        //    snapshot, so nothing the ball passes over (yard lines, scrimmage line, end
        //    zones, uprights) is ever smeared or erased.
        //    The kick view is a backdrop only: no ball carrier (this is not a scrimmage
        //    play) and no first-down marker (yardsToGain 0), so the scrimmage line reads
        //    in its own blue instead of the marker's yellow.
        drawField(yardLine: startYardLine, down: 4, yardsToGain: 0,
                  possessingTeam: dir > 0 ? 0 : 1, offensiveOffset: 0,
                  showBallCarrier: false)
        let backdrop = pixelBuffer

        // 2. Turn the supplied result into a flight: distance, hang time, apex, drift.
        let flightYards: Double          // ground distance in the air, in yards
        let flightTime: Double           // seconds in the air
        let peakHeight: Double           // apex height in pixels
        let lateralDrift: Double         // total sideways drift over the flight, in pixels
        let hopYards: Double             // short roll after the ball comes down, in yards

        /// Where a punt or kickoff comes down: the reported spot, or inside the end zone for
        /// a touchback (the game spots the ball on the receiving team's 20 afterwards).
        func landingSpot(_ spotYardLine: Int, touchback: Bool) -> Double {
            guard touchback else { return Double(spotYardLine) }
            return Double(dir > 0 ? 100 : 0) + dirD * Double.random(in: 5...12)
        }

        switch outcome {
        case .fieldGoal(let result):
            let dist = max(5.0, abs(postYard - Double(startYardLine)))   // yards to the posts
            peakHeight = Double.random(in: 16...20)
            flightTime = 1.1 + dist * 0.012
            hopYards = 0
            switch result {
            case .good:
                // Through the uprights: cross the posts inside the gap.
                flightYards = dist / goalPlaneFraction
                lateralDrift = Double.random(in: -(halfGap - 2.5)...(halfGap - 2.5)) / goalPlaneFraction
            case .wideLeft, .wideRight:
                // Past the outside of an upright.
                flightYards = dist / goalPlaneFraction
                let side: Double = result == .wideLeft ? -1 : 1
                lateralDrift = side * Double.random(in: (halfGap + 2.0)...(halfGap + 7.0)) / goalPlaneFraction
            case .short:
                // Comes down before it ever reaches the posts.
                flightYards = dist * Double.random(in: 0.78...0.94)
                lateralDrift = Double.random(in: -3...3)
            }

        case .punt(let spotYardLine, let isTouchback):
            let distance = max(1.0, abs(landingSpot(spotYardLine, touchback: isTouchback) - Double(startYardLine)))
            hopYards = min(Double.random(in: 1...4), max(0.0, distance - 1.0))
            flightYards = distance - hopYards
            flightTime = 1.4 + flightYards * 0.017
            peakHeight = Double.random(in: 17...21)
            lateralDrift = Double.random(in: -4...4)

        case .kickoff(let spotYardLine, let isTouchback):
            let distance = max(1.0, abs(landingSpot(spotYardLine, touchback: isTouchback) - Double(startYardLine)))
            hopYards = min(Double.random(in: 2...5), max(0.0, distance - 1.0))
            flightYards = distance - hopYards
            flightTime = 2.2 + flightYards * 0.005
            peakHeight = Double.random(in: 21...25)
            lateralDrift = Double.random(in: -3...3)
        }

        let hasHop = hopYards > 0
        let hopTime = 0.4
        let hopHeight = hasHop ? peakHeight * 0.2 : 0.0
        let totalTime = flightTime + (hasHop ? hopTime : 0.0)

        /// Ball state at `elapsed` seconds: ground X, ground lateral (Y), and height above ground.
        /// Ground track is a straight line (constant speed); height is a true parabola that
        /// returns to exactly 0 when the ball comes down, then a smaller hop.
        func state(at elapsed: Double) -> (gx: Double, lat: Double, h: Double) {
            if elapsed < flightTime {
                let s = elapsed / flightTime
                return (startX + dirD * flightYards * pxPerYard * s,
                        centerLat + lateralDrift * s,
                        4.0 * peakHeight * s * (1.0 - s))
            }
            let s = hasHop ? min(1.0, (elapsed - flightTime) / hopTime) : 1.0
            return (startX + dirD * (flightYards + hopYards * s) * pxPerYard,
                    centerLat + lateralDrift,
                    4.0 * hopHeight * s * (1.0 - s))
        }

        // 3. Play it on the real clock so the speed doesn't depend on frame timing.
        let startNanos = DispatchTime.now().uptimeNanoseconds
        while true {
            guard isCurrent(generation) else { return false }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000_000.0
            let elapsed = min(seconds, totalTime)
            let st = state(at: elapsed)
            renderKickFrame(backdrop: backdrop, gx: st.gx, lat: st.lat, height: st.h)
            commitFrame()
            if elapsed >= totalTime { break }
            guard await pause(nanoseconds: 33_000_000) else { return false }
        }

        // Leave the ball sitting where it came to rest for a moment.
        guard await pause(nanoseconds: 450_000_000), isCurrent(generation) else { return false }
        return true
    }

    /// Draws one kick frame: backdrop, then the ground shadow, then the ball lifted by `height`.
    private func renderKickFrame(backdrop: [UInt8], gx: Double, lat: Double, height: Double) {
        pixelBuffer = backdrop

        let sx = Int(gx.rounded()) - 1          // top-left of the 2×2 sprite on the ground
        let sy = Int(lat.rounded()) - 1

        // Shadow on the ground track (black); thins out as the ball climbs.
        let shadowRows = height >= 2.5 ? 1 : 2
        let shadowY = height >= 2.5 ? sy + 1 : sy
        for dy in 0..<shadowRows {
            for dx in 0..<2 {
                setPixel(x: sx + dx, y: shadowY + dy, color: 0)
            }
        }

        // Ball (orange, COLOR=8 in the original), drawn straight "up" the screen by its height.
        let ballY = sy - Int(height.rounded())
        for dy in 0..<2 {
            for dx in 0..<2 {
                setPixel(x: sx + dx, y: ballY + dy, color: 8)
            }
        }
    }

    /// Bakes a goal post standing at the back of an end zone, drawn with a slight oblique
    /// perspective: height goes up the screen (the same convention the ball uses) and also
    /// leans `lean` pixels per two pixels of height toward the field, so the post reads as a
    /// 3D structure instead of collapsing onto one column. The post is a short yellow stem,
    /// a white crossbar, and two yellow uprights rising from the crossbar ends. Called from
    /// `bakeStaticField`, so the posts are part of the field background on every screen.
    /// - Parameters:
    ///   - baseX: screen X where the post stands on the ground
    ///   - lean: +1 leans right (left end zone), -1 leans left (right end zone)
    private func bakeGoalPosts(into buf: UnsafeMutablePointer<UInt8>, baseX: Int, lean: Int) {
        let width = AppleIIGraphicsEngine.width
        let height = AppleIIGraphicsEngine.height
        let centerLat = Int(AppleIIGraphicsEngine.kickCenterLat)
        let halfGap = Int(AppleIIGraphicsEngine.goalHalfGap)
        let barH = Int(AppleIIGraphicsEngine.goalCrossbarHeight)
        let topH = Int(AppleIIGraphicsEngine.goalUprightHeight)

        // Screen position of a ground point at `lat` lifted by `h` pixels.
        func screen(_ lat: Int, _ h: Int) -> (x: Int, y: Int) {
            (baseX + lean * ((h + 1) / 2), lat - h)
        }

        func put(_ x: Int, _ y: Int, _ color: UInt8) {
            guard x >= 0 && x < width && y >= 0 && y < height else { return }
            buf[y * width + x] = color
        }

        // Simple integer line (Bresenham)
        func line(_ a: (x: Int, y: Int), _ b: (x: Int, y: Int), _ color: UInt8) {
            var x = a.x, y = a.y
            let dx = abs(b.x - a.x), dy = -abs(b.y - a.y)
            let sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
            var err = dx + dy
            while true {
                put(x, y, color)
                if x == b.x && y == b.y { break }
                let e2 = 2 * err
                if e2 >= dy { err += dy; x += sx }
                if e2 <= dx { err += dx; y += sy }
            }
        }

        let yellow: UInt8 = 13
        let white: UInt8 = 15

        let barLeft = screen(centerLat - halfGap, barH)     // crossbar end on the near upright
        let barRight = screen(centerLat + halfGap, barH)    // crossbar end on the far upright
        let stemBase = screen(centerLat, 0)
        let stemTop = screen(centerLat, barH)

        line(stemBase, stemTop, yellow)                                           // stem
        line(barLeft, screen(centerLat - halfGap, topH), yellow)                  // upright
        line(barRight, screen(centerLat + halfGap, topH), yellow)                 // upright
        line(barLeft, barRight, white)                                            // crossbar
    }

    // MARK: - Native Fast Field Rendering

    /// Draws the field for the current down and spot.
    /// - Parameter offensiveOffset: Ball carrier offset from the scrimmage line, in yards
    ///   (negative = behind the line). Converted to pixels at the field's own scale.
    /// - Parameter showBallCarrier: pass false for backdrops that are not a scrimmage snap
    ///   (the kick animations), so no stray carrier marker is painted onto the field.
    func drawField(
        yardLine: Int = 20,
        down: Int = 1,
        yardsToGain: Int = 10,
        possessingTeam: Int = 0,
        offensiveOffset: Double = -3,
        showBallCarrier: Bool = true
    ) {
        let width = AppleIIGraphicsEngine.width
        let height = AppleIIGraphicsEngine.height
        let marginTop = 8
        let marginBottom = 88
        let fieldStartX = 24
        let fieldWidthPixels = AppleIIGraphicsEngine.fieldWidthPixels
        
        pixelBuffer.withUnsafeMutableBufferPointer { ptr in
            guard let buf = ptr.baseAddress else { return }
            
            // 1. Instant memcpy of pre-baked field background
            staticFieldBuffer.withUnsafeBufferPointer { staticPtr in
                guard let staticBuf = staticPtr.baseAddress else { return }
                memcpy(buf, staticBuf, AppleIIGraphicsEngine.totalPixels)
            }
            
            // 2. First-down marker, then the line of scrimmage. Draw order matters: when
            //    yardsToGain is 0 both lines land on the same column, and the blue LOS has
            //    to win over the yellow marker rather than the other way around.
            let ballX = fieldStartX + Int((Double(yardLine) / 100.0) * fieldWidthPixels)
            let targetYard = possessingTeam == 0 ? min(100, yardLine + yardsToGain) : max(0, yardLine - yardsToGain)
            let targetX = fieldStartX + Int((Double(targetYard) / 100.0) * fieldWidthPixels)
            
            for y in marginTop..<marginBottom {
                let rowOffset = y * width
                buf[rowOffset + targetX] = 13 // Yellow 1st Down Marker
                buf[rowOffset + ballX] = 2    // Blue Line of Scrimmage
            }
            
            // 3. Ball Carrier Marker (2x2)
            guard showBallCarrier else { return }
            let direction = possessingTeam == 0 ? 1 : -1
            let offsetPixels = Int((offensiveOffset * AppleIIGraphicsEngine.pxPerYard).rounded())
            let currentOffenseX = ballX + (offsetPixels * direction)
            let carrierY = height / 2
            
            for dy in 0..<2 {
                let rowOffset = (carrierY + dy) * width
                for dx in 0..<2 {
                    let targetX = currentOffenseX + dx
                    if targetX >= 0 && targetX < width {
                        buf[rowOffset + targetX] = 13
                    }
                }
            }
        }
    }
}
