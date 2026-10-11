import Foundation
import SwiftUI
import AppKit

@MainActor
class AppleIIGraphicsEngine: ObservableObject {
    static let width = 160
    static let height = 96
    static let totalPixels = width * height
    
    // Output image for SwiftUI view (zero-cost UI redrawing)
    @Published var currentFrame: CGImage?
    
    // Raw pixel buffer
    public var pixelBuffer = [UInt8](repeating: 0, count: totalPixels)
    
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
    
    /// Forces a update of the Published CGImage frame to refresh the UI
    func presentFrame() {
        updateFrameImage()
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
        
        updateFrameImage()
    }
    
    // MARK: - Jumbotron Startup Animation Sequence

    func playStartupAnimation(onComplete: @escaping () -> Void) async {
        let splashBuffer = getOrLoadSplashBuffer()
        
        clear(color: 0)
        updateFrameImage()
        try? await Task.sleep(nanoseconds: 100_000_000)
        
        let totalFrames = 20
        for frame in 1...totalFrames {
            let progress = Double(frame) / Double(totalFrames)
            let easeOutProgress = 1.0 - pow(1.0 - progress, 2)
            let currentScale = 0.05 + (0.95 * easeOutProgress)
            
            drawScaledSplash(scale: currentScale, sourceBuffer: splashBuffer)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        
        drawScaledSplash(scale: 1.0, sourceBuffer: splashBuffer)
        onComplete()
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
        
        updateFrameImage()
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

    /// Plays a top-down kick animation (punt, kickoff or field goal).
    ///
    /// The field is viewed from above, so screen X is downfield, screen Y is lateral,
    /// and altitude is shown by drawing a shadow on the ground track and lifting the
    /// ball sprite straight up the screen by its height.
    ///
    /// - Parameters:
    ///   - startYardLine: Kicker's yard line (0–100, same scale as `drawField`)
    ///   - isFieldGoal: true = field goal attempt, kicked through the posts at the back of the end zone
    ///   - direction: +1 (kicking toward yard 100) or -1 (kicking toward yard 0)
    ///   - isKickoff: true = kickoff distance/hang time instead of a punt (ignored for field goals)
    ///   - onComplete: `isGood` is only ever true for a made field goal. `finalYardLine` is the
    ///     spot where the ball ended up (0–100). A punt or kickoff that ends in the end zone is a
    ///     touchback and reports the receiving team's own 20 (80 when kicking toward 100, 20 when
    ///     kicking toward 0).
    func playKickAnimation(
        startYardLine: Int,
        isFieldGoal: Bool,
        direction: Int,
        isKickoff: Bool = false,
        onComplete: @escaping (_ isGood: Bool, _ finalYardLine: Int) -> Void
    ) async {
        let dir = direction >= 0 ? 1 : -1
        let dirD = Double(dir)
        let fieldStartX = 24.0
        let fieldWidthPixels = 112.0
        let pxPerYard = fieldWidthPixels / 100.0
        let centerLat = AppleIIGraphicsEngine.kickCenterLat
        let halfGap = AppleIIGraphicsEngine.goalHalfGap
        let crossbarClearance = AppleIIGraphicsEngine.goalCrossbarHeight   // min ball height to clear the bar
        // Field goals are kicked to the posts at the back of the end zone, expressed in yards.
        let postX = Double(dir > 0 ? AppleIIGraphicsEngine.goalPostRightX : AppleIIGraphicsEngine.goalPostLeftX)
        let postYard = (postX - fieldStartX) / pxPerYard

        // 1. Draw the static backdrop once, then snapshot it. Every frame starts from this
        //    snapshot, so nothing the ball passes over (yard lines, scrimmage line, end
        //    zones, uprights) is ever smeared or erased.
        drawField(yardLine: startYardLine, down: 4, yardsToGain: 0,
                  possessingTeam: dir > 0 ? 0 : 1, offensiveOffset: 0)
        let backdrop = pixelBuffer

        // 2. Decide the kick up front (distance, hang time, peak height, sideways drift),
        //    then derive the whole trajectory from those numbers.
        let flightYards: Double          // ground distance of the first flight, in yards
        let flightTime: Double           // seconds in the air
        let peakHeight: Double           // apex height in pixels
        let lateralDrift: Double         // total sideways drift over the flight, in pixels
        let bounceYards: Double          // extra ground covered by one small hop after landing
        var planeFraction: Double? = nil // fraction of flight at which the goal plane is crossed

        if isFieldGoal {
            let dist = max(5.0, abs(postYard - Double(startYardLine)))   // yards to the posts
            let effective = dist + 3.0   // dist already includes the end zone; add the holder's 7 yds, less rounding
            let makeChance = min(0.97, max(0.2, 1.0 - max(0.0, effective - 30.0) * 0.0125))
            let planeFrac = 0.93         // a kick that reaches the posts crosses them at 93% of flight
            peakHeight = Double.random(in: 16...20)
            flightTime = 1.1 + dist * 0.012
            bounceYards = 0

            if Double.random(in: 0..<1) < makeChance {
                // Through the uprights
                flightYards = dist / planeFrac
                let target = Double.random(in: -(halfGap - 2.5)...(halfGap - 2.5))
                lateralDrift = target / planeFrac
            } else if Bool.random() {
                // Wide left / wide right
                flightYards = dist / planeFrac
                let side: Double = Bool.random() ? 1 : -1
                let target = side * Double.random(in: (halfGap + 2.0)...(halfGap + 7.0))
                lateralDrift = target / planeFrac
            } else {
                // Short: lands before reaching the posts
                flightYards = dist * Double.random(in: 0.78...0.94)
                lateralDrift = Double.random(in: -3...3)
            }
            if flightYards >= dist { planeFraction = dist / flightYards }
        } else if isKickoff {
            flightYards = Double.random(in: 60...72)
            flightTime = Double.random(in: 2.2...2.6)
            peakHeight = Double.random(in: 21...25)
            lateralDrift = Double.random(in: -3...3)
            bounceYards = Double.random(in: 2...5)
        } else {
            flightYards = Double.random(in: 36...52)
            flightTime = 1.4 + flightYards * 0.017
            peakHeight = Double.random(in: 17...21)
            lateralDrift = Double.random(in: -4...4)
            bounceYards = Double.random(in: 1...4)
        }

        let startX = fieldStartX + Double(startYardLine) * pxPerYard
        let hasBounce = bounceYards > 0
        let bounceTime = 0.4
        let bounceHeight = hasBounce ? peakHeight * 0.2 : 0.0
        let totalTime = flightTime + (hasBounce ? bounceTime : 0.0)

        /// Ball state at `elapsed` seconds: ground X, ground lateral (Y), and height above ground.
        /// Ground track is a straight line (constant speed); height is a true parabola that
        /// returns to exactly 0 at touchdown.
        func state(at elapsed: Double) -> (gx: Double, lat: Double, h: Double) {
            if elapsed < flightTime {
                let s = elapsed / flightTime
                return (startX + dirD * flightYards * pxPerYard * s,
                        centerLat + lateralDrift * s,
                        4.0 * peakHeight * s * (1.0 - s))
            }
            let s = hasBounce ? min(1.0, (elapsed - flightTime) / bounceTime) : 1.0
            return (startX + dirD * (flightYards + bounceYards * s) * pxPerYard,
                    centerLat + lateralDrift,
                    4.0 * bounceHeight * s * (1.0 - s))
        }

        // 3. Work out the result from the trajectory itself.
        let landingYard = Double(startYardLine) + dirD * (flightYards + bounceYards)
        var isGood = false
        let finalYard: Int

        if isFieldGoal {
            // Judge the kick at the goal-post plane: it must be between the uprights
            // and above the crossbar at the moment it crosses.
            if let pf = planeFraction {
                let st = state(at: pf * flightTime)
                isGood = abs(st.lat - centerLat) <= (halfGap - 0.5) && st.h >= crossbarClearance
            }
            finalYard = Int(max(0.0, min(100.0, landingYard.rounded())))
        } else if landingYard > 100.0 || landingYard < 0.0 {
            finalYard = dir > 0 ? 80 : 20          // touchback
        } else {
            finalYard = Int(landingYard.rounded())
        }

        // 4. Animate on the real clock so the speed doesn't depend on frame timing.
        let startNanos = DispatchTime.now().uptimeNanoseconds
        while true {
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000_000.0
            let elapsed = min(seconds, totalTime)
            let st = state(at: elapsed)
            renderKickFrame(backdrop: backdrop, gx: st.gx, lat: st.lat, height: st.h)
            if elapsed >= totalTime || Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 33_000_000)
        }

        // Leave the ball sitting where it came to rest for a moment.
        try? await Task.sleep(nanoseconds: 450_000_000)

        onComplete(isGood, finalYard)
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

        presentFrame()
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

    func drawField(yardLine: Int = 20, down: Int = 1, yardsToGain: Int = 10, possessingTeam: Int = 0, offensiveOffset: Int = -3) {
        let width = AppleIIGraphicsEngine.width
        let height = AppleIIGraphicsEngine.height
        let marginTop = 8
        let marginBottom = 88
        let fieldStartX = 24
        let fieldWidthPixels = 112.0
        
        pixelBuffer.withUnsafeMutableBufferPointer { ptr in
            guard let buf = ptr.baseAddress else { return }
            
            // 1. Instant memcpy of pre-baked field background
            staticFieldBuffer.withUnsafeBufferPointer { staticPtr in
                guard let staticBuf = staticPtr.baseAddress else { return }
                memcpy(buf, staticBuf, AppleIIGraphicsEngine.totalPixels)
            }
            
            // 2. Line of Scrimmage & Target Line
            let ballX = fieldStartX + Int((Double(yardLine) / 100.0) * fieldWidthPixels)
            let targetYard = possessingTeam == 0 ? min(100, yardLine + yardsToGain) : max(0, yardLine - yardsToGain)
            let targetX = fieldStartX + Int((Double(targetYard) / 100.0) * fieldWidthPixels)
            
            for y in marginTop..<marginBottom {
                let rowOffset = y * width
                buf[rowOffset + ballX] = 2   // Blue Line of Scrimmage
                buf[rowOffset + targetX] = 13 // Yellow 1st Down Marker
            }
            
            // 3. Ball Carrier Marker (2x2)
            let direction = possessingTeam == 0 ? 1 : -1
            let scaledOffset = offensiveOffset * 2
            let currentOffenseX = ballX + (scaledOffset * direction)
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
        
        updateFrameImage()
    }
}
