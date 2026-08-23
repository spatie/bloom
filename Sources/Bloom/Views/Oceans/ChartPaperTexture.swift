import SwiftUI
import CoreGraphics

/// The paper itself, baked into two small bitmaps once per launch.
///
/// **Why procedural and not a scan.** A photographed sheet of aged rag paper is the better
/// looking answer and it was the first thing considered. It was not taken, for two reasons that
/// both had to hold. The first is provenance: a texture ships inside the app, so its licence
/// has to be one this project can stand behind rather than one a stock site asserts on a page
/// that can change, and every candidate that survived a reading of its actual terms was either
/// too small to cover a window or came with an attribution clause an offline app has nowhere to
/// honour. The second is size: this chart's whole coastline dataset is 22.8KB, and a bitmap
/// large enough to cover eight tenths of a large display at retina without repeating is several
/// megabytes. Both objections disappear here. Nothing is shipped, nothing is licensed, and the
/// two images below come to half a megabyte of pixels generated in twelve milliseconds, once.
///
/// **Why not Core Image.** The obvious procedural route is `CIRandomGenerator` through blurs,
/// and it was tried. The trouble is the tile: a tiled texture is the only way to get device
/// resolution grain across a large window without holding a full screen bitmap, and Core Image's
/// blurs do not wrap, so every tile seam arrives as a visible line where the blur ran out of
/// pixels to average. Wrapping is not an effect that can be added afterwards, it has to be in
/// the noise, so the noise is generated here on a lattice whose index wraps. Seamless comes out
/// of the arithmetic rather than being fought for, and the whole generator is shorter than the
/// filter chain it replaces.
///
/// **What paper is, in three layers.** Grain is the tooth of the sheet, one or two device pixels
/// across, and it must be at device resolution or it reads as blur. Fibre is the same thing
/// stretched: pulp lies down in the direction the sheet was drawn off the wire, so the noise is
/// eight times longer than it is tall. Formation is the cloudiness held up to a light, where the
/// pulp settled thicker in some places than others, and it is what a flat fill can never fake.
/// The first two are high frequency and tile; the third is low frequency and is generated once
/// as a small field stretched over the whole window, which costs nothing and cannot be seen to
/// be stretched because there is nothing sharp in it.
@MainActor
enum ChartPaperTexture {
    /// 256 device pixels. Large enough that the eye cannot find the repeat in grain this fine,
    /// small enough that the tile is a quarter of a megabyte whatever size the window is.
    static let tileSize = 256

    /// The formation field's own resolution. Roughly the chart's proportions, so the stains are
    /// not badly stretched in the common case, and low because everything in it is soft.
    static let fieldWidth = 320
    static let fieldHeight = 200

    /// The tooth of the sheet: grain, fibre and weave, tiling seamlessly.
    static let tile: CGImage = makeTile()

    /// Formation, foxing and water stains, stretched across the window.
    static let field: CGImage = makeField()

    // MARK: The tile

    private static func makeTile() -> CGImage {
        let side = tileSize
        var grain = ChartGrain(seed: 0x9A17_E4D2)
        // Cells per tile, so a larger number is a finer feature. `fine` at one cell per pixel is
        // the tooth; `fibre` is eight times longer across than down, which is the direction the
        // pulp lay in; `weave` is the coarser unevenness of the felt the sheet was pressed on.
        let fine = WrapNoise(cellsX: side, cellsY: side, grain: &grain)
        let fibre = WrapNoise(cellsX: side / 8, cellsY: side, grain: &grain)
        let weave = WrapNoise(cellsX: side / 3, cellsY: side / 3, grain: &grain)

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            let v = (Double(y) + 0.5) / Double(side)
            for x in 0..<side {
                let u = (Double(x) + 0.5) / Double(side)
                let value = 0.52 * fine.sample(u, v)
                    + 0.34 * fibre.sample(u, v)
                    + 0.14 * weave.sample(u, v)
                // Three uniforms summed cluster near the middle, so most of the sheet is nearly
                // untouched and only the occasional fleck reaches the amplitude below. That is
                // the distribution paper has, and it is why a flat noise looks like static.
                let signed = (value - 0.5) * 2
                let index = (y * side + x) * 4
                if signed < 0 {
                    // A darker fibre. Black rather than a brown, because the pigment here is the
                    // paper's own shadow and it has to work over water, land and ink alike.
                    let alpha = min(1, -signed * 0.14)
                    pixels[index + 3] = UInt8(alpha * 255)
                } else {
                    let alpha = min(1, signed * 0.105)
                    let premultiplied = UInt8(alpha * 255)
                    pixels[index] = premultiplied
                    pixels[index + 1] = premultiplied
                    pixels[index + 2] = premultiplied
                    pixels[index + 3] = premultiplied
                }
            }
        }
        return image(from: pixels, width: side, height: side)
    }

    // MARK: The field

    private static func makeField() -> CGImage {
        let width = fieldWidth
        let height = fieldHeight
        var grain = ChartGrain(seed: 0xB13D_7C05)
        let broad = WrapNoise(cellsX: 3, cellsY: 2, grain: &grain)
        let middle = WrapNoise(cellsX: 7, cellsY: 5, grain: &grain)
        let close = WrapNoise(cellsX: 16, cellsY: 11, grain: &grain)
        // The damp is a second noise field with a threshold taken through it, not a set of
        // discs. Discs were the first version and they looked like a tray of drink rings: eleven
        // circles of similar size scattered evenly, each one obviously the same shape rotated.
        // A threshold through noise cannot make a circle, so what comes out has the lobes and
        // inlets a real stain has, and the coastline of one stain is nothing like the next.
        let damp = WrapNoise(cellsX: 6, cellsY: 4, grain: &grain)
        let dampDetail = WrapNoise(cellsX: 13, cellsY: 9, grain: &grain)
        let dampEdge = WrapNoise(cellsX: 27, cellsY: 18, grain: &grain)
        // The warp: the field is sampled at coordinates the warp has pushed around, which drags
        // the threshold's contour sideways by different amounts in different places. It is what
        // turns a rounded blob into something that has run.
        let warpX = WrapNoise(cellsX: 5, cellsY: 4, grain: &grain)
        let warpY = WrapNoise(cellsX: 4, cellsY: 5, grain: &grain)

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let v = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                let formation = (0.5 * broad.sample(u, v)
                    + 0.32 * middle.sample(u, v)
                    + 0.18 * close.sample(u, v) - 0.5) * 2

                let warpedU = u + (warpX.sample(u, v) - 0.5) * 0.14
                let warpedV = v + (warpY.sample(u, v) - 0.5) * 0.14
                let wet = 0.62 * damp.sample(warpedU, warpedV)
                    + 0.26 * dampDetail.sample(warpedU, warpedV)
                    + 0.12 * dampEdge.sample(warpedU, warpedV)
                // Where the sheet dried. Below the shoreline nothing happened; above it the
                // pigment sits, and right on it there is a tideline, the darker rim damp leaves
                // as it retreats and carries what it dissolved to the edge of where it reached.
                let shore = 0.615
                let body = smoothstep(shore, shore + 0.16, wet) * 0.85
                let tideline = exp(-pow((wet - shore - 0.010) / 0.030, 2)) * 0.48
                let stained = min(body + tideline, 1.2)

                // Three pigments over the paper: the shadow where the sheet is thicker, the
                // highlight where the light comes through it, and the brown a stain dried to.
                // They are fixed rather than taken from the appearance, because the sheet is the
                // same sheet in the dark and only the lamp over it changes.
                var red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0
                if formation < 0 {
                    let a = -formation * 0.085
                    red += 0.29 * a; green += 0.22 * a; blue += 0.13 * a; alpha += a
                } else {
                    let a = formation * 0.055
                    red += a; green += a; blue += 0.94 * a; alpha += a
                }
                if stained > 0 {
                    let a = stained * 0.085
                    red += 0.54 * a; green += 0.38 * a; blue += 0.18 * a; alpha += a
                }
                let index = (y * width + x) * 4
                pixels[index] = UInt8(min(red, 1) * 255)
                pixels[index + 1] = UInt8(min(green, 1) * 255)
                pixels[index + 2] = UInt8(min(blue, 1) * 255)
                pixels[index + 3] = UInt8(min(alpha, 1) * 255)
            }
        }
        return image(from: pixels, width: width, height: height)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Pixels to an image

    /// Premultiplied because that is what the compositor wants anyway, and because both layers
    /// above are built by adding pigment rather than by blending it, which is premultiplied
    /// arithmetic already.
    private static func image(from pixels: [UInt8], width: Int, height: Int) -> CGImage {
        var pixels = pixels
        let made: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        // A failure here means the parameters above are wrong, which is a build time mistake and
        // not a runtime one, so an empty pixel is a truthful stand in rather than a crash in a
        // window whose whole job is decoration.
        return made ?? blankImage()
    }

    private static func blankImage() -> CGImage {
        var pixel: [UInt8] = [0, 0, 0, 0]
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return context!.makeImage()!
    }
}

/// Value noise on a lattice whose index wraps, which is the whole trick behind a seamless tile:
/// the cell to the right of the last one is the first one, so the right edge interpolates back
/// into the left and there is no seam to hide. Smoothstep between cells rather than a straight
/// line, because linear interpolation leaves a crease along every lattice edge that the eye
/// picks out as a grid the moment several octaves line up.
struct WrapNoise {
    private let cellsX: Int
    private let cellsY: Int
    private let values: [Double]

    init(cellsX: Int, cellsY: Int, grain: inout ChartGrain) {
        self.cellsX = max(1, cellsX)
        self.cellsY = max(1, cellsY)
        var values: [Double] = []
        values.reserveCapacity(self.cellsX * self.cellsY)
        for _ in 0..<(self.cellsX * self.cellsY) { values.append(grain.next()) }
        self.values = values
    }

    /// `u` and `v` in zero to one. Anything outside wraps, which is free here.
    func sample(_ u: Double, _ v: Double) -> Double {
        let x = u * Double(cellsX)
        let y = v * Double(cellsY)
        let xFloor = x.rounded(.down)
        let yFloor = y.rounded(.down)
        let fx = smooth(x - xFloor)
        let fy = smooth(y - yFloor)
        let x0 = wrap(Int(xFloor), cellsX)
        let y0 = wrap(Int(yFloor), cellsY)
        let x1 = (x0 + 1) % cellsX
        let y1 = (y0 + 1) % cellsY
        let top = values[y0 * cellsX + x0] + (values[y0 * cellsX + x1] - values[y0 * cellsX + x0]) * fx
        let bottom = values[y1 * cellsX + x0] + (values[y1 * cellsX + x1] - values[y1 * cellsX + x0]) * fx
        return top + (bottom - top) * fy
    }

    private func wrap(_ value: Int, _ count: Int) -> Int {
        let remainder = value % count
        return remainder < 0 ? remainder + count : remainder
    }

    private func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}

/// A small fixed sequence for grain and jitter. Not `SystemRandomNumberGenerator`, because
/// the paper must not re-speckle on every redraw, and not `srand48`, because two windows
/// would share its global state. SplitMix64, which is four lines and passes for paper.
struct ChartGrain {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
