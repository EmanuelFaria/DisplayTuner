// DisplayTunerV3.swift — Professional macOS Display Calibration Suite
// Compile: swiftc -O Sources/DisplayTunerV3.swift -o DisplayTuner -framework AppKit -framework CoreImage -framework QuartzCore
// Single-file native AppKit app. No SwiftUI, no Xcode project.

import AppKit
import CoreGraphics
import CoreImage
import QuartzCore
import Foundation

// MARK: - Data Types

struct CurvePoint: Codable {
    var x: CGFloat
    var y: CGFloat
}

enum CurveChannel: Int, CaseIterable, Codable {
    case master = 0, red = 1, green = 2, blue = 3
    case cyan = 4, magenta = 5, yellow = 6, black = 7

    var title: String {
        switch self {
        case .master: return "Master"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        case .cyan: return "C"
        case .magenta: return "M"
        case .yellow: return "Y"
        case .black: return "K"
        }
    }

    var color: NSColor {
        switch self {
        case .master: return .white
        case .red: return NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.2, alpha: 1.0)
        case .green: return NSColor(calibratedRed: 0.2, green: 0.9, blue: 0.2, alpha: 1.0)
        case .blue: return NSColor(calibratedRed: 0.3, green: 0.4, blue: 1.0, alpha: 1.0)
        case .cyan: return NSColor(calibratedRed: 0.0, green: 0.85, blue: 0.85, alpha: 1.0)
        case .magenta: return NSColor(calibratedRed: 0.85, green: 0.0, blue: 0.85, alpha: 1.0)
        case .yellow: return NSColor(calibratedRed: 0.9, green: 0.9, blue: 0.0, alpha: 1.0)
        case .black: return NSColor(calibratedWhite: 0.55, alpha: 1.0)
        }
    }
}

struct TonalEQState: Codable {
    // 8 channels x 12 bands each
    var bands: [Int: [Double]] // channel rawValue -> [12 band values]

    init() {
        bands = [:]
        for ch in CurveChannel.allCases {
            bands[ch.rawValue] = [Double](repeating: 0.0, count: 12)
        }
    }
}

struct PresetData: Codable {
    var curves: [Int: [CurvePoint]] // channel rawValue -> points
    var tonalEQ: TonalEQState
    var whitePointKelvin: Double
    var previewOn: Bool
    var targetGamma: Double?

    init() {
        curves = [:]
        for ch in CurveChannel.allCases {
            curves[ch.rawValue] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        }
        tonalEQ = TonalEQState()
        whitePointKelvin = 6500
        previewOn = true
        targetGamma = 2.2
    }
}

struct UndoState {
    var curves: [Int: [CurvePoint]]
    var tonalBands: [Int: [Double]]
    var whitePointKelvin: Double
    var targetGamma: Double
}

// MARK: - Color Math: CIE Lab conversions

func srgbToLinear(_ c: Double) -> Double {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

func linearToSRGB(_ c: Double) -> Double {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
}

func srgbToXYZ(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let rl = srgbToLinear(r)
    let gl = srgbToLinear(g)
    let bl = srgbToLinear(b)
    let x = 0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl
    let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
    let z = 0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl
    return (x, y, z)
}

func xyzToLab(_ x: Double, _ y: Double, _ z: Double,
              refX: Double = 0.95047, refY: Double = 1.0, refZ: Double = 1.08883) -> (Double, Double, Double) {
    func f(_ t: Double) -> Double {
        return t > 0.008856 ? pow(t, 1.0 / 3.0) : (903.3 * t + 16.0) / 116.0
    }
    let fx = f(x / refX)
    let fy = f(y / refY)
    let fz = f(z / refZ)
    let L = 116.0 * fy - 16.0
    let a = 500.0 * (fx - fy)
    let b = 200.0 * (fy - fz)
    return (L, a, b)
}

func srgbToLab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let (x, y, z) = srgbToXYZ(r, g, b)
    return xyzToLab(x, y, z)
}

// MARK: - CIEDE2000 (Sharma et al. 2005)

func ciede2000(_ L1: Double, _ a1: Double, _ b1: Double,
               _ L2: Double, _ a2: Double, _ b2: Double) -> Double {
    let pi = Double.pi
    let pow25_7: Double = 6103515625.0 // 25^7

    let C1 = sqrt(a1 * a1 + b1 * b1)
    let C2 = sqrt(a2 * a2 + b2 * b2)
    let Cab = (C1 + C2) / 2.0

    let Cab7 = pow(Cab, 7.0)
    let G = 0.5 * (1.0 - sqrt(Cab7 / (Cab7 + pow25_7)))

    let a1p = a1 * (1.0 + G)
    let a2p = a2 * (1.0 + G)

    let C1p = sqrt(a1p * a1p + b1 * b1)
    let C2p = sqrt(a2p * a2p + b2 * b2)

    var h1p = atan2(b1, a1p) * 180.0 / pi
    if h1p < 0 { h1p += 360.0 }
    var h2p = atan2(b2, a2p) * 180.0 / pi
    if h2p < 0 { h2p += 360.0 }

    let dLp = L2 - L1
    let dCp = C2p - C1p

    var dhp: Double
    if C1p * C2p == 0 {
        dhp = 0
    } else if abs(h2p - h1p) <= 180 {
        dhp = h2p - h1p
    } else if h2p - h1p > 180 {
        dhp = h2p - h1p - 360
    } else {
        dhp = h2p - h1p + 360
    }

    let dHp = 2.0 * sqrt(C1p * C2p) * sin(dhp / 2.0 * pi / 180.0)

    let Lp = (L1 + L2) / 2.0
    let Cp = (C1p + C2p) / 2.0

    var hp: Double
    if C1p * C2p == 0 {
        hp = h1p + h2p
    } else if abs(h1p - h2p) <= 180 {
        hp = (h1p + h2p) / 2.0
    } else if h1p + h2p < 360 {
        hp = (h1p + h2p + 360) / 2.0
    } else {
        hp = (h1p + h2p - 360) / 2.0
    }

    let T = 1.0
        - 0.17 * cos((hp - 30) * pi / 180)
        + 0.24 * cos((2 * hp) * pi / 180)
        + 0.32 * cos((3 * hp + 6) * pi / 180)
        - 0.20 * cos((4 * hp - 63) * pi / 180)

    let Lp50sq = (Lp - 50) * (Lp - 50)
    let SL = 1.0 + 0.015 * Lp50sq / sqrt(20 + Lp50sq)
    let SC = 1.0 + 0.045 * Cp
    let SH = 1.0 + 0.015 * Cp * T

    let Cp7 = pow(Cp, 7.0)
    let RC = 2.0 * sqrt(Cp7 / (Cp7 + pow25_7))
    let dtheta = 30.0 * exp(-((hp - 275) / 25.0) * ((hp - 275) / 25.0))
    let RT = -sin(2.0 * dtheta * pi / 180.0) * RC

    let termL = dLp / SL
    let termC = dCp / SC
    let termH = dHp / SH

    return sqrt(termL * termL + termC * termC + termH * termH + RT * termC * termH)
}

// MARK: - Bradford Chromatic Adaptation

func kelvinToXY(_ kelvin: Double) -> (Double, Double) {
    let T = kelvin
    var x: Double
    if T <= 4000 {
        x = -0.2661239e9 / (T * T * T) - 0.2343589e6 / (T * T) + 0.8776956e3 / T + 0.179910
    } else {
        x = -3.0258469e9 / (T * T * T) + 2.1070379e6 / (T * T) + 0.2226347e3 / T + 0.24039
    }
    var y: Double
    if T <= 2222 {
        y = -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
    } else if T <= 4000 {
        y = -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
    } else {
        y = 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
    }
    return (x, y)
}

func xyToXYZ(_ x: Double, _ y: Double) -> (Double, Double, Double) {
    guard y > 0.0001 else { return (0, 0, 0) }
    return (x / y, 1.0, (1.0 - x - y) / y)
}

func bradfordGains(sourceKelvin: Double, destKelvin: Double) -> (Double, Double, Double) {
    // Bradford matrix
    let M: [[Double]] = [
        [ 0.8951,  0.2664, -0.1614],
        [-0.7502,  1.7135,  0.0367],
        [ 0.0389, -0.0685,  1.0296]
    ]

    let (sx, sy) = kelvinToXY(sourceKelvin)
    let (sX, sY, sZ) = xyToXYZ(sx, sy)

    let (dx, dy) = kelvinToXY(destKelvin)
    let (dX, dY, dZ) = xyToXYZ(dx, dy)

    // Transform to cone response domain
    let sR = M[0][0] * sX + M[0][1] * sY + M[0][2] * sZ
    let sG = M[1][0] * sX + M[1][1] * sY + M[1][2] * sZ
    let sB = M[2][0] * sX + M[2][1] * sY + M[2][2] * sZ

    let dR = M[0][0] * dX + M[0][1] * dY + M[0][2] * dZ
    let dG = M[1][0] * dX + M[1][1] * dY + M[1][2] * dZ
    let dB = M[2][0] * dX + M[2][1] * dY + M[2][2] * dZ

    // Simplified: return per-channel gains (diagonal adaptation)
    let rGain = (sR != 0) ? dR / sR : 1.0
    let gGain = (sG != 0) ? dG / sG : 1.0
    let bGain = (sB != 0) ? dB / sB : 1.0

    return (rGain, gGain, bGain)
}

// MARK: - Monotone Cubic Hermite Interpolation (Fritsch-Carlson)

func monotonicCubicInterpolation(points: [CurvePoint], steps: Int = 256) -> [CGFloat] {
    guard points.count >= 2 else {
        return (0..<steps).map { CGFloat($0) / CGFloat(steps - 1) }
    }

    let sorted = points.sorted { $0.x < $1.x }
    let n = sorted.count

    var dx = [CGFloat](repeating: 0, count: n - 1)
    var dy = [CGFloat](repeating: 0, count: n - 1)
    var slopes = [CGFloat](repeating: 0, count: n - 1)

    for i in 0..<(n - 1) {
        dx[i] = sorted[i + 1].x - sorted[i].x
        dy[i] = sorted[i + 1].y - sorted[i].y
        slopes[i] = dx[i] > 0.0001 ? dy[i] / dx[i] : 0
    }

    var tangents = [CGFloat](repeating: 0, count: n)
    tangents[0] = slopes[0]
    tangents[n - 1] = slopes[n - 2]

    for i in 1..<(n - 1) {
        if slopes[i - 1] * slopes[i] <= 0 {
            tangents[i] = 0
        } else {
            tangents[i] = (slopes[i - 1] + slopes[i]) / 2.0
        }
    }

    for i in 0..<(n - 1) {
        if abs(slopes[i]) < 0.0001 {
            tangents[i] = 0
            tangents[i + 1] = 0
        } else {
            let alpha = tangents[i] / slopes[i]
            let beta = tangents[i + 1] / slopes[i]
            let sum = alpha * alpha + beta * beta
            if sum > 9 {
                let tau = 3.0 / sqrt(sum)
                tangents[i] = tau * alpha * slopes[i]
                tangents[i + 1] = tau * beta * slopes[i]
            }
        }
    }

    var result = [CGFloat](repeating: 0, count: steps)
    for step in 0..<steps {
        let t = CGFloat(step) / CGFloat(steps - 1)

        if t <= sorted[0].x {
            if n > 1 && sorted[0].x > 0.0001 {
                result[step] = max(0, min(1, sorted[0].y + tangents[0] * (t - sorted[0].x)))
            } else {
                result[step] = sorted[0].y
            }
            continue
        }
        if t >= sorted[n - 1].x {
            if n > 1 && sorted[n - 1].x < 0.9999 {
                result[step] = max(0, min(1, sorted[n - 1].y + tangents[n - 1] * (t - sorted[n - 1].x)))
            } else {
                result[step] = sorted[n - 1].y
            }
            continue
        }

        var seg = 0
        for i in 0..<(n - 1) {
            if t >= sorted[i].x && t <= sorted[i + 1].x {
                seg = i
                break
            }
        }

        let h = dx[seg]
        if h < 0.0001 { result[step] = sorted[seg].y; continue }

        let tt = (t - sorted[seg].x) / h
        let tt2 = tt * tt
        let tt3 = tt2 * tt

        let h00 = 2 * tt3 - 3 * tt2 + 1
        let h10 = tt3 - 2 * tt2 + tt
        let h01 = -2 * tt3 + 3 * tt2
        let h11 = tt3 - tt2

        let val = h00 * sorted[seg].y + h10 * h * tangents[seg] +
                  h01 * sorted[seg + 1].y + h11 * h * tangents[seg + 1]
        result[step] = max(0, min(1, val))
    }

    return result
}

// MARK: - Gaussian Weight

func gaussianWeight(_ x: CGFloat, center: CGFloat, sigma: CGFloat) -> CGFloat {
    let diff = x - center
    return exp(-(diff * diff) / (2 * sigma * sigma))
}

// MARK: - Signal Handler for Crash Safety

func installSignalHandlers() {
    signal(SIGTERM) { _ in
        CGDisplayRestoreColorSyncSettings()
        exit(0)
    }
    signal(SIGINT) { _ in
        CGDisplayRestoreColorSyncSettings()
        exit(0)
    }
}

// MARK: - CurveView (520x520 Curve Grid)

class CurveView: NSView {
    static let gridSize: CGFloat = 520
    static let padding: CGFloat = 2

    var channel: CurveChannel = .master { didSet { needsDisplay = true } }

    var points: [CurvePoint] = [
        CurvePoint(x: 0, y: 0),
        CurvePoint(x: 1, y: 1)
    ]

    var onCurveChanged: (() -> Void)?

    private var dragIndex: Int? = nil
    private let hitRadius: CGFloat = 10.0

    var curveArea: NSRect {
        return NSRect(x: CurveView.padding, y: CurveView.padding,
                      width: CurveView.gridSize, height: CurveView.gridSize)
    }

    override var isFlipped: Bool { return false }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let area = curveArea

        // Background
        NSColor(calibratedWhite: 0.10, alpha: 1.0).setFill()
        NSBezierPath(rect: area).fill()

        // Vertical gridlines at EQ band positions
        NSColor(calibratedWhite: 0.22, alpha: 1.0).setStroke()
        for center in tonalBandCenters {
            let frac = CGFloat(center)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: area.minX + frac * area.width, y: area.minY))
            path.line(to: NSPoint(x: area.minX + frac * area.width, y: area.maxY))
            path.lineWidth = 0.5
            path.stroke()
        }
        // Horizontal gridlines at 25%
        for i in 1...3 {
            let frac = CGFloat(i) * 0.25
            let path = NSBezierPath()
            path.move(to: NSPoint(x: area.minX, y: area.minY + frac * area.height))
            path.line(to: NSPoint(x: area.maxX, y: area.minY + frac * area.height))
            path.lineWidth = 0.5
            path.stroke()
        }

        // Border
        NSColor(calibratedWhite: 0.35, alpha: 1.0).setStroke()
        let borderPath = NSBezierPath(rect: area)
        borderPath.lineWidth = 1.0
        borderPath.stroke()

        // Diagonal reference (identity)
        NSColor(calibratedWhite: 0.30, alpha: 0.7).setStroke()
        let diagPath = NSBezierPath()
        diagPath.move(to: NSPoint(x: area.minX, y: area.minY))
        diagPath.line(to: NSPoint(x: area.maxX, y: area.maxY))
        diagPath.lineWidth = 1.0
        diagPath.setLineDash([4, 4], count: 2, phase: 0)
        diagPath.stroke()

        // Draw curve
        let lut = monotonicCubicInterpolation(points: points, steps: 256)
        channel.color.setStroke()
        let curvePath = NSBezierPath()
        for i in 0..<256 {
            let px = area.minX + CGFloat(i) / 255.0 * area.width
            let py = area.minY + lut[i] * area.height
            if i == 0 { curvePath.move(to: NSPoint(x: px, y: py)) }
            else { curvePath.line(to: NSPoint(x: px, y: py)) }
        }
        curvePath.lineWidth = 2.0
        curvePath.lineCapStyle = .round
        curvePath.lineJoinStyle = .round
        curvePath.stroke()

        // Control points
        for (idx, pt) in points.enumerated() {
            let px = area.minX + pt.x * area.width
            let py = area.minY + pt.y * area.height
            let pointRect = NSRect(x: px - 5, y: py - 5, width: 10, height: 10)

            NSColor.white.setStroke()
            let outerPath = NSBezierPath(ovalIn: pointRect)
            outerPath.lineWidth = 1.5
            outerPath.stroke()

            if idx == dragIndex {
                channel.color.withAlphaComponent(0.9).setFill()
            } else {
                NSColor(calibratedWhite: 0.15, alpha: 0.9).setFill()
            }
            outerPath.fill()
        }
    }

    private func pointInCurveSpace(_ event: NSEvent) -> NSPoint {
        let loc = convert(event.locationInWindow, from: nil)
        let area = curveArea
        let x = (loc.x - area.minX) / area.width
        let y = (loc.y - area.minY) / area.height
        return NSPoint(x: max(0, min(1, x)), y: max(0, min(1, y)))
    }

    private func hitTest(at curvePoint: NSPoint) -> Int? {
        let area = curveArea
        for (idx, pt) in points.enumerated() {
            let px = area.minX + pt.x * area.width
            let py = area.minY + pt.y * area.height
            let cpx = area.minX + curvePoint.x * area.width
            let cpy = area.minY + curvePoint.y * area.height
            let dist = sqrt((px - cpx) * (px - cpx) + (py - cpy) * (py - cpy))
            if dist < hitRadius { return idx }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let cp = pointInCurveSpace(event)
        if let idx = hitTest(at: cp) {
            dragIndex = idx
            needsDisplay = true
        } else {
            let newPt = CurvePoint(x: cp.x, y: cp.y)
            points.append(newPt)
            points.sort { $0.x < $1.x }
            for (idx, pt) in points.enumerated() {
                if abs(pt.x - newPt.x) < 0.001 && abs(pt.y - newPt.y) < 0.001 {
                    dragIndex = idx
                    break
                }
            }
            needsDisplay = true
            onCurveChanged?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let idx = dragIndex else { return }
        let cp = pointInCurveSpace(event)
        points[idx] = CurvePoint(x: cp.x, y: cp.y)
        let draggedPoint = points[idx]
        points.sort { $0.x < $1.x }
        for (i, pt) in points.enumerated() {
            if abs(pt.x - draggedPoint.x) < 0.0001 && abs(pt.y - draggedPoint.y) < 0.0001 {
                dragIndex = i
                break
            }
        }
        needsDisplay = true
        onCurveChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        dragIndex = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let cp = pointInCurveSpace(event)
        if let idx = hitTest(at: cp) {
            if points.count > 2 {
                points.remove(at: idx)
                needsDisplay = true
                onCurveChanged?()
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
    override var acceptsFirstResponder: Bool { return true }
}

// MARK: - Tonal EQ Band Constants

let tonalBandCenters: [Double] = [0.02, 0.07, 0.12, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 0.97]
let tonalBandLabels: [String] = ["Blk", "DSh", "Shd", "LSh", "LMd", "MLo", "Mid", "MHi", "HMd", "Hlt", "HLt", "PkW"]
let tonalBandSigma: Double = 0.05

// MARK: - ColorChecker Reference Data

struct ColorCheckerPatch {
    let id: Int
    let name: String
    let L: Double
    let a: Double
    let b: Double
}

let colorCheckerPatches: [ColorCheckerPatch] = [
    ColorCheckerPatch(id: 1, name: "Dark Skin", L: 37.986, a: 13.555, b: 14.059),
    ColorCheckerPatch(id: 2, name: "Light Skin", L: 65.711, a: 18.130, b: 17.810),
    ColorCheckerPatch(id: 3, name: "Blue Sky", L: 49.927, a: -4.880, b: -21.925),
    ColorCheckerPatch(id: 4, name: "Foliage", L: 43.139, a: -13.095, b: 21.905),
    ColorCheckerPatch(id: 5, name: "Blue Flower", L: 55.112, a: 8.844, b: -25.399),
    ColorCheckerPatch(id: 6, name: "Bluish Green", L: 70.719, a: -33.397, b: -0.199),
    ColorCheckerPatch(id: 7, name: "Orange", L: 62.661, a: 36.067, b: 57.096),
    ColorCheckerPatch(id: 8, name: "Purplish Blue", L: 40.020, a: 10.410, b: -45.964),
    ColorCheckerPatch(id: 9, name: "Moderate Red", L: 51.124, a: 48.239, b: 16.248),
    ColorCheckerPatch(id: 10, name: "Purple", L: 30.325, a: 22.976, b: -21.587),
    ColorCheckerPatch(id: 11, name: "Yellow Green", L: 72.532, a: -23.709, b: 57.255),
    ColorCheckerPatch(id: 12, name: "Orange Yellow", L: 71.941, a: 19.363, b: 67.857),
    ColorCheckerPatch(id: 13, name: "Blue", L: 28.778, a: 14.179, b: -50.297),
    ColorCheckerPatch(id: 14, name: "Green", L: 55.261, a: -38.342, b: 31.370),
    ColorCheckerPatch(id: 15, name: "Red", L: 42.101, a: 53.378, b: 28.190),
    ColorCheckerPatch(id: 16, name: "Yellow", L: 81.733, a: 4.039, b: 79.819),
    ColorCheckerPatch(id: 17, name: "Magenta", L: 51.935, a: 49.986, b: -14.574),
    ColorCheckerPatch(id: 18, name: "Cyan", L: 51.038, a: -28.631, b: -28.638),
    ColorCheckerPatch(id: 19, name: "White", L: 96.539, a: -0.425, b: 1.186),
    ColorCheckerPatch(id: 20, name: "Neutral 8", L: 81.257, a: -0.638, b: -0.335),
    ColorCheckerPatch(id: 21, name: "Neutral 6.5", L: 66.766, a: -0.734, b: -0.504),
    ColorCheckerPatch(id: 22, name: "Neutral 5", L: 50.867, a: -0.153, b: -0.270),
    ColorCheckerPatch(id: 23, name: "Neutral 3.5", L: 35.656, a: -0.421, b: -1.231),
    ColorCheckerPatch(id: 24, name: "Black", L: 20.461, a: -0.079, b: -0.973),
]

// Approximate sRGB values for ColorChecker patches (D50->D65 adapted)
let colorCheckerSRGB: [(Double, Double, Double)] = [
    (0.459, 0.310, 0.259), // 1  Dark Skin
    (0.757, 0.576, 0.502), // 2  Light Skin
    (0.353, 0.424, 0.569), // 3  Blue Sky
    (0.349, 0.399, 0.251), // 4  Foliage
    (0.490, 0.459, 0.639), // 5  Blue Flower
    (0.424, 0.741, 0.659), // 6  Bluish Green
    (0.784, 0.502, 0.161), // 7  Orange
    (0.278, 0.310, 0.608), // 8  Purplish Blue
    (0.690, 0.314, 0.322), // 9  Moderate Red
    (0.286, 0.204, 0.369), // 10 Purple
    (0.588, 0.733, 0.251), // 11 Yellow Green
    (0.831, 0.600, 0.141), // 12 Orange Yellow
    (0.173, 0.224, 0.514), // 13 Blue
    (0.298, 0.537, 0.251), // 14 Green
    (0.584, 0.224, 0.220), // 15 Red
    (0.898, 0.808, 0.157), // 16 Yellow
    (0.631, 0.318, 0.467), // 17 Magenta
    (0.208, 0.451, 0.545), // 18 Cyan
    (0.953, 0.945, 0.920), // 19 White
    (0.788, 0.784, 0.769), // 20 Neutral 8
    (0.616, 0.616, 0.604), // 21 Neutral 6.5
    (0.447, 0.447, 0.439), // 22 Neutral 5
    (0.294, 0.294, 0.282), // 23 Neutral 3.5
    (0.137, 0.137, 0.129), // 24 Black
]

// MARK: - Test Pattern View

class TestPatternView: NSView {
    enum PatternType: Int {
        case grayscale = 0
        case nearBlack = 1
        case nearWhite = 2
        case colorChecker = 3
        case gammaVerify = 4
        case rgbPrimaries = 5
        case skinTones = 6
    }

    var patternType: PatternType = .grayscale { didSet { needsDisplay = true } }
    override var isFlipped: Bool { return true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let w = bounds.width
        let h = bounds.height

        NSColor.black.setFill()
        NSBezierPath(rect: bounds).fill()

        switch patternType {
        case .grayscale:
            drawGrayscale(w: w, h: h)
        case .nearBlack:
            drawNearBlack(w: w, h: h)
        case .nearWhite:
            drawNearWhite(w: w, h: h)
        case .colorChecker:
            drawColorChecker(w: w, h: h)
        case .gammaVerify:
            drawGammaVerify(w: w, h: h)
        case .rgbPrimaries:
            drawRGBPrimaries(w: w, h: h)
        case .skinTones:
            drawSkinTones(w: w, h: h)
        }
    }

    private func drawGrayscale(w: CGFloat, h: CGFloat) {
        let steps = 21
        let patchW = w / CGFloat(steps)
        for i in 0..<steps {
            let v = CGFloat(i) / CGFloat(steps - 1)
            NSColor(calibratedWhite: v, alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(i) * patchW, y: 0, width: patchW, height: h)).fill()
            // Label
            let label = String(format: "%d%%", Int(v * 100))
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: v > 0.5 ? NSColor.black : NSColor.white,
                .font: NSFont.systemFont(ofSize: 10)
            ]
            (label as NSString).draw(at: NSPoint(x: CGFloat(i) * patchW + 2, y: h - 16), withAttributes: attrs)
        }
    }

    private func drawNearBlack(w: CGFloat, h: CGFloat) {
        let levels: [CGFloat] = [0, 0.01, 0.02, 0.03, 0.04, 0.05]
        let patchW = w / CGFloat(levels.count)
        for (i, v) in levels.enumerated() {
            NSColor(calibratedWhite: v, alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(i) * patchW, y: 0, width: patchW, height: h)).fill()
            let label = String(format: "%d%%", Int(v * 100))
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 12)
            ]
            (label as NSString).draw(at: NSPoint(x: CGFloat(i) * patchW + 4, y: h / 2), withAttributes: attrs)
        }
    }

    private func drawNearWhite(w: CGFloat, h: CGFloat) {
        let levels: [CGFloat] = [0.95, 0.96, 0.97, 0.98, 0.99, 1.0]
        let patchW = w / CGFloat(levels.count)
        for (i, v) in levels.enumerated() {
            NSColor(calibratedWhite: v, alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(i) * patchW, y: 0, width: patchW, height: h)).fill()
            let label = String(format: "%d%%", Int(v * 100))
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(calibratedWhite: 0.5, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 12)
            ]
            (label as NSString).draw(at: NSPoint(x: CGFloat(i) * patchW + 4, y: h / 2), withAttributes: attrs)
        }
    }

    private func drawColorChecker(w: CGFloat, h: CGFloat) {
        let cols = 6
        let rows = 4
        let patchW = w / CGFloat(cols)
        let patchH = h / CGFloat(rows)

        for (idx, srgb) in colorCheckerSRGB.enumerated() {
            let row = idx / cols
            let col = idx % cols
            let color = NSColor(calibratedRed: CGFloat(srgb.0), green: CGFloat(srgb.1), blue: CGFloat(srgb.2), alpha: 1.0)
            color.setFill()
            let rect = NSRect(x: CGFloat(col) * patchW + 1, y: CGFloat(row) * patchH + 1,
                              width: patchW - 2, height: patchH - 2)
            NSBezierPath(rect: rect).fill()

            // Compute Delta-E 2000 vs reference
            let patch = colorCheckerPatches[idx]
            let (labL, labA, labB) = srgbToLab(srgb.0, srgb.1, srgb.2)
            let dE = ciede2000(patch.L, patch.a, patch.b, labL, labA, labB)

            let deColor: NSColor
            if dE < 1.0 { deColor = NSColor(calibratedRed: 0.2, green: 0.9, blue: 0.2, alpha: 1.0) }
            else if dE < 3.0 { deColor = NSColor(calibratedRed: 0.9, green: 0.9, blue: 0.0, alpha: 1.0) }
            else { deColor = NSColor(calibratedRed: 1.0, green: 0.2, blue: 0.2, alpha: 1.0) }

            let nameAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: deColor,
                .font: NSFont.boldSystemFont(ofSize: 9)
            ]
            let deStr = String(format: "dE=%.1f", dE)
            (deStr as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 3), withAttributes: nameAttrs)

            let nameLabel = patch.name
            let nlAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
                .font: NSFont.systemFont(ofSize: 8)
            ]
            (nameLabel as NSString).draw(at: NSPoint(x: rect.minX + 3, y: rect.minY + 16), withAttributes: nlAttrs)
        }
    }

    private func drawGammaVerify(w: CGFloat, h: CGFloat) {
        let gammas: [Double] = [1.8, 2.0, 2.2, 2.4, 2.6]
        let patchW = w / CGFloat(gammas.count)
        let patchH = h

        for (i, gamma) in gammas.enumerated() {
            let x0 = CGFloat(i) * patchW

            // Left half: alternating 0 and 1 lines (checkerboard)
            // Should appear as ~50% gray when display gamma matches
            let checkSize: CGFloat = 1.0
            for row in stride(from: CGFloat(0), to: patchH, by: checkSize * 2) {
                NSColor.white.setFill()
                NSBezierPath(rect: NSRect(x: x0, y: row, width: patchW / 2, height: checkSize)).fill()
                NSColor.black.setFill()
                NSBezierPath(rect: NSRect(x: x0, y: row + checkSize, width: patchW / 2, height: checkSize)).fill()
            }

            // Right half: solid mid-gray at the gamma value
            let midGray = pow(0.5, 1.0 / gamma)
            NSColor(calibratedWhite: CGFloat(midGray), alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(x: x0 + patchW / 2, y: 0, width: patchW / 2, height: patchH)).fill()

            // Label
            let label = String(format: "%.1f", gamma)
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.boldSystemFont(ofSize: 14),
                .backgroundColor: NSColor.black.withAlphaComponent(0.5)
            ]
            (label as NSString).draw(at: NSPoint(x: x0 + patchW / 2 - 15, y: 10), withAttributes: attrs)
        }
    }

    private func drawRGBPrimaries(w: CGFloat, h: CGFloat) {
        let colors: [(CGFloat, CGFloat, CGFloat, String)] = [
            (1, 0, 0, "Red"), (0, 1, 0, "Green"), (0, 0, 1, "Blue"),
            (0, 1, 1, "Cyan"), (1, 0, 1, "Magenta"), (1, 1, 0, "Yellow"),
        ]
        let patchW = w / CGFloat(colors.count)
        for (i, c) in colors.enumerated() {
            NSColor(calibratedRed: c.0, green: c.1, blue: c.2, alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(i) * patchW, y: 0, width: patchW, height: h)).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.boldSystemFont(ofSize: 12),
                .backgroundColor: NSColor.black.withAlphaComponent(0.4)
            ]
            (c.3 as NSString).draw(at: NSPoint(x: CGFloat(i) * patchW + 4, y: h / 2), withAttributes: attrs)
        }
    }

    private func drawSkinTones(w: CGFloat, h: CGFloat) {
        let skinTones: [(CGFloat, CGFloat, CGFloat, String)] = [
            (0.96, 0.87, 0.78, "Fair"),
            (0.89, 0.76, 0.62, "Light"),
            (0.78, 0.61, 0.44, "Medium"),
            (0.63, 0.44, 0.29, "Olive"),
            (0.47, 0.31, 0.20, "Brown"),
            (0.33, 0.22, 0.14, "Dark"),
        ]
        let patchW = w / CGFloat(skinTones.count)
        for (i, s) in skinTones.enumerated() {
            NSColor(calibratedRed: s.0, green: s.1, blue: s.2, alpha: 1.0).setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(i) * patchW, y: 0, width: patchW, height: h)).fill()
            let textColor: NSColor = (s.0 + s.1 + s.2) / 3.0 > 0.5 ? .black : .white
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: 11)
            ]
            (s.3 as NSString).draw(at: NSPoint(x: CGFloat(i) * patchW + 4, y: h / 2), withAttributes: attrs)
        }
    }
}

// MARK: - Test Pattern Window Controller

class TestPatternController: NSObject, NSWindowDelegate {
    var windows: [NSWindow] = []
    var patternViews: [TestPatternView] = []
    var currentPatternType: TestPatternView.PatternType = .grayscale

    func showWindow() {
        if !windows.isEmpty {
            windows.forEach { $0.makeKeyAndOrderFront(nil) }
            return
        }
        // Get all screens and create one window per screen
        let screens = NSScreen.screens
        for (i, screen) in screens.enumerated() {
            createPatternWindow(on: screen, index: i)
        }
    }

    func createPatternWindow(on screen: NSScreen, index: Int) {
        let frame = screen.frame
        let contentRect = NSRect(x: frame.origin.x + 50, y: frame.origin.y + 50,
                                 width: min(frame.width - 100, 1200),
                                 height: min(frame.height - 100, 800))
        let w = NSWindow(contentRect: contentRect,
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        let displayName = "\(Int(frame.width))x\(Int(frame.height))"
        w.title = "Test Patterns — Display \(index + 1) (\(displayName))"
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black

        let cv = w.contentView!

        // Toolbar at top — pinned using autoresizing
        let toolbar = NSView(frame: NSRect(x: 0, y: contentRect.height - 40,
                                           width: contentRect.width, height: 40))
        toolbar.autoresizingMask = [.width, .minYMargin]
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor

        let selector = NSPopUpButton(frame: NSRect(x: 10, y: 7, width: 200, height: 26))
        selector.addItems(withTitles: [
            "Grayscale Ramp", "Near-Black (0-5%)", "Near-White (95-100%)",
            "ColorChecker 24", "Gamma Verify", "RGB Primaries", "Skin Tones"
        ])
        selector.selectItem(at: currentPatternType.rawValue)
        selector.tag = index
        selector.target = self
        selector.action = #selector(patternChanged(_:))
        toolbar.addSubview(selector)

        let fsButton = NSButton(frame: NSRect(x: 220, y: 7, width: 120, height: 26))
        fsButton.title = "Full Screen (F)"
        fsButton.bezelStyle = .rounded
        fsButton.tag = index
        fsButton.target = self
        fsButton.action = #selector(toggleFullScreen(_:))
        toolbar.addSubview(fsButton)

        cv.addSubview(toolbar)

        let pv = TestPatternView(frame: NSRect(x: 0, y: 0,
                                               width: contentRect.width,
                                               height: contentRect.height - 40))
        pv.autoresizingMask = [.width, .height]
        pv.patternType = currentPatternType
        cv.addSubview(pv)

        windows.append(w)
        patternViews.append(pv)

        w.makeKeyAndOrderFront(nil)
    }

    @objc func patternChanged(_ sender: NSPopUpButton) {
        if let pt = TestPatternView.PatternType(rawValue: sender.indexOfSelectedItem) {
            currentPatternType = pt
            // Update ALL pattern views to the same pattern
            for pv in patternViews {
                pv.patternType = pt
            }
        }
    }

    @objc func toggleFullScreen(_ sender: NSButton) {
        let idx = sender.tag
        if idx < windows.count {
            windows[idx].toggleFullScreen(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Remove closed window from tracking
        if let w = notification.object as? NSWindow, let idx = windows.firstIndex(of: w) {
            windows.remove(at: idx)
            if idx < patternViews.count { patternViews.remove(at: idx) }
        }
    }
}

// MARK: - Main Controller

class DisplayTunerController: NSObject, NSWindowDelegate {
    var window: NSWindow!
    var curveView: CurveView!
    var displayPopup: NSPopUpButton!
    var channelButtons: [NSButton] = []

    // Tonal EQ
    var tonalEQSliders: [Int: [NSSlider]] = [:] // channel rawValue -> 12 sliders
    var tonalEQLabels: [Int: [NSTextField]] = [:]
    var tonalEQChannel: CurveChannel = .master
    var tonalChannelButtons: [NSButton] = []
    var tonalSliderContainer: NSView!

    // White point
    var whitePointKelvin: Double = 6500.0
    var kelvinSlider: NSSlider!
    var kelvinLabel: NSTextField!

    // Preview
    var previewOn: Bool = false
    var previewButton: NSButton!
    var liveIndicator: NSTextField!

    // Warm-up timer
    var warmUpTimer: Timer?
    var warmUpSecondsRemaining: Int = 1200 // 20 minutes
    var warmUpLabel: NSTextField!

    // State
    var currentChannel: CurveChannel = .master
    var curves: [Int: [CurvePoint]] = [:]
    var tonalBands: [Int: [Double]] = [:]
    var displayIDs: [CGDirectDisplayID] = []
    var userHasInteracted: Bool = false

    // Undo/Redo
    var undoStack: [UndoState] = []
    var redoStack: [UndoState] = []
    let maxUndoStates = 50

    // Enhanced precision (temporal dithering)
    var temporalDitheringEnabled: Bool = false
    var displayLink: CVDisplayLink?
    var ditheringFrame: Int = 0
    var lastRTable: [Float] = []
    var lastGTable: [Float] = []
    var lastBTable: [Float] = []

    // Test patterns
    var testPatternController = TestPatternController()

    // Cross-Display Calibration (v4)
    var referenceDisplayPopup: NSPopUpButton!
    var referenceDisplayIDs: [CGDirectDisplayID] = []
    var colorMatchPairs: [(source: NSColor, target: NSColor)] = []
    var colorMatchStatusLabel: NSTextField!
    var colorMatchCountLabel: NSTextField!
    var colorMatchStep: Int = 0  // 0=idle, 1=waiting for source pick, 2=waiting for target pick
    var pendingSourceColor: NSColor?
    var matchColorButton: NSButton!
    var quickMatchButton: NSButton!
    var doneMatchingButton: NSButton!

    // Target Gamma
    var targetGamma: Double = 2.2
    var gammaSlider: NSSlider!
    var gammaLabel: NSTextField!

    let windowWidth: CGFloat = 1100
    let windowHeight: CGFloat = 950

    override init() {
        super.init()
        initCurves()
        initTonalBands()
    }

    func initCurves() {
        for ch in CurveChannel.allCases {
            curves[ch.rawValue] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        }
    }

    func initTonalBands() {
        for ch in CurveChannel.allCases {
            tonalBands[ch.rawValue] = [Double](repeating: 0.0, count: 12)
        }
    }

    // MARK: - Build UI

    func buildUI() {
        let contentRect = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)
        window = NSWindow(contentRect: contentRect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "DisplayTuner v3"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 900)
        window.center()
        window.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1.0)

        let cv = window.contentView!
        cv.wantsLayer = true

        buildTopBar(cv)
        buildLeftPanel(cv)
        buildRightPanel(cv)
        buildBottomBar(cv)

        startWarmUpTimer()

        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Top Bar

    func buildTopBar(_ cv: NSView) {
        let topY = windowHeight - 38

        // Display selector
        let displayLabel = makeLabel("Display:", x: 15, y: topY, width: 55)
        displayLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        cv.addSubview(displayLabel)

        displayPopup = NSPopUpButton(frame: NSRect(x: 72, y: topY - 2, width: 320, height: 26))
        displayPopup.target = self
        displayPopup.action = #selector(displayChanged(_:))
        cv.addSubview(displayPopup)
        populateDisplays()

        // Warm-up timer
        warmUpLabel = makeLabel("Warm-up: 20:00", x: 430, y: topY, width: 140)
        warmUpLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        warmUpLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.7, blue: 0.2, alpha: 1.0)
        warmUpLabel.alignment = .center
        cv.addSubview(warmUpLabel)

        // LIVE indicator
        liveIndicator = makeLabel("OFF", x: windowWidth - 100, y: topY, width: 80)
        liveIndicator.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        liveIndicator.textColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)
        liveIndicator.alignment = .right
        cv.addSubview(liveIndicator)
    }

    // MARK: - Left Panel (Curves only)

    func buildLeftPanel(_ cv: NSView) {
        let panelX: CGFloat = 15
        var y = windowHeight - 68

        // Channel tabs for curves
        let rgbChannels: [CurveChannel] = [.master, .red, .green, .blue]
        let cmykChannels: [CurveChannel] = [.cyan, .magenta, .yellow, .black]

        var tabX: CGFloat = panelX
        for ch in rgbChannels {
            let btn = makeTabButton(ch, x: tabX, y: y, tag: ch.rawValue)
            btn.target = self
            btn.action = #selector(channelTabClicked(_:))
            cv.addSubview(btn)
            channelButtons.append(btn)
            tabX += btn.frame.width + 3
        }

        let sep = makeLabel("|", x: tabX, y: y, width: 12)
        sep.textColor = NSColor(calibratedWhite: 0.4, alpha: 1.0)
        cv.addSubview(sep)
        tabX += 14

        for ch in cmykChannels {
            let btn = makeTabButton(ch, x: tabX, y: y, tag: ch.rawValue)
            btn.target = self
            btn.action = #selector(channelTabClicked(_:))
            cv.addSubview(btn)
            channelButtons.append(btn)
            tabX += btn.frame.width + 3
        }
        updateCurveTabHighlight()

        // Curve view 520x520
        y -= (CurveView.gridSize + CurveView.padding * 2 + 6)
        let curveSize = CurveView.gridSize + CurveView.padding * 2
        curveView = CurveView(frame: NSRect(x: panelX, y: y, width: curveSize, height: curveSize))
        curveView.channel = currentChannel
        curveView.points = curves[currentChannel.rawValue]!
        curveView.onCurveChanged = { [weak self] in
            self?.curveDidChange()
        }
        cv.addSubview(curveView)

        // Info label
        y -= 18
        let infoLabel = makeLabel("Click to add points. Drag to move. Right-click to delete.",
                                  x: panelX, y: y, width: curveSize)
        infoLabel.font = NSFont.systemFont(ofSize: 9)
        infoLabel.textColor = NSColor(calibratedWhite: 0.50, alpha: 1.0)
        cv.addSubview(infoLabel)
    }

    // MARK: - Right Panel (Controls)

    func buildRightPanel(_ cv: NSView) {
        let panelX: CGFloat = 560
        let panelW: CGFloat = windowWidth - panelX - 15
        var y = windowHeight - 68

        // White Point section
        let wpHeader = makeLabel("White Point", x: panelX, y: y, width: 100)
        wpHeader.font = NSFont.boldSystemFont(ofSize: 11)
        cv.addSubview(wpHeader)

        y -= 28
        // Preset buttons
        let presets: [(String, Double)] = [("D50", 5003), ("D55", 5503), ("D65", 6504), ("D75", 7504)]
        var bx: CGFloat = panelX
        for (label, kelvin) in presets {
            let btn = NSButton(frame: NSRect(x: bx, y: y, width: 50, height: 24))
            btn.title = label
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 10)
            btn.tag = Int(kelvin)
            btn.target = self
            btn.action = #selector(whitePointPreset(_:))
            cv.addSubview(btn)
            bx += 54
        }

        // Kelvin slider
        y -= 26
        let kLabel = makeLabel("Kelvin:", x: panelX, y: y + 2, width: 48)
        kLabel.font = NSFont.systemFont(ofSize: 10)
        cv.addSubview(kLabel)

        kelvinSlider = NSSlider(frame: NSRect(x: panelX + 50, y: y, width: panelW - 110, height: 20))
        kelvinSlider.minValue = 3200
        kelvinSlider.maxValue = 9300
        kelvinSlider.doubleValue = 6500
        kelvinSlider.isContinuous = true
        kelvinSlider.target = self
        kelvinSlider.action = #selector(kelvinSliderChanged(_:))
        cv.addSubview(kelvinSlider)

        kelvinLabel = makeLabel("6500K", x: panelX + panelW - 55, y: y + 2, width: 60)
        kelvinLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        cv.addSubview(kelvinLabel)

        // Separator line
        y -= 16
        let sep1 = NSBox(frame: NSRect(x: panelX, y: y, width: panelW, height: 1))
        sep1.boxType = .separator
        cv.addSubview(sep1)

        // Eyedropper buttons
        y -= 30
        let pickBlack = makeActionButton("Pick Black", x: panelX, y: y, width: 90, action: #selector(pickBlackPoint(_:)))
        let pickWhite = makeActionButton("Pick White", x: panelX + 95, y: y, width: 90, action: #selector(pickWhitePoint(_:)))
        let pickGray = makeActionButton("Pick Gray", x: panelX + 190, y: y, width: 90, action: #selector(pickGrayPoint(_:)))
        cv.addSubview(pickBlack)
        cv.addSubview(pickWhite)
        cv.addSubview(pickGray)

        // Separator
        y -= 16
        let sep2 = NSBox(frame: NSRect(x: panelX, y: y, width: panelW, height: 1))
        sep2.boxType = .separator
        cv.addSubview(sep2)

        // Sharpening section (stubbed)
        y -= 24
        let sharpHeader = makeLabel("Sharpening", x: panelX, y: y, width: 100)
        sharpHeader.font = NSFont.boldSystemFont(ofSize: 11)
        cv.addSubview(sharpHeader)

        y -= 18
        let stubLabel = makeLabel("Coming Soon", x: panelX, y: y, width: panelW)
        stubLabel.font = NSFont.systemFont(ofSize: 9)
        stubLabel.textColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)
        cv.addSubview(stubLabel)

        // Separator
        y -= 16
        let sep3 = NSBox(frame: NSRect(x: panelX, y: y, width: panelW, height: 1))
        sep3.boxType = .separator
        cv.addSubview(sep3)

        // Preview toggle
        y -= 32
        previewButton = NSButton(frame: NSRect(x: panelX, y: y, width: 130, height: 28))
        previewButton.title = "Preview OFF"
        previewButton.bezelStyle = .rounded
        previewButton.target = self
        previewButton.action = #selector(togglePreview(_:))
        cv.addSubview(previewButton)

        // Undo / Redo
        y -= 32
        let undoBtn = makeActionButton("Undo", x: panelX, y: y, width: 80, action: #selector(undoAction(_:)))
        let redoBtn = makeActionButton("Redo", x: panelX + 85, y: y, width: 80, action: #selector(redoAction(_:)))
        cv.addSubview(undoBtn)
        cv.addSubview(redoBtn)

        // Enhanced precision checkbox
        y -= 28
        let ditheringCheck = NSButton(checkboxWithTitle: "Enhanced Precision", target: self,
                                       action: #selector(toggleDithering(_:)))
        ditheringCheck.frame = NSRect(x: panelX, y: y, width: 180, height: 20)
        ditheringCheck.state = .off
        if #available(macOS 10.14, *) {
            ditheringCheck.contentTintColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)
        }
        cv.addSubview(ditheringCheck)

        // Separator
        y -= 16
        let sep4 = NSBox(frame: NSRect(x: panelX, y: y, width: panelW, height: 1))
        sep4.boxType = .separator
        cv.addSubview(sep4)

        // Action buttons
        y -= 30
        let resetBtn = makeActionButton("Reset All", x: panelX, y: y, width: 85, action: #selector(resetAll(_:)))
        let saveBtn = makeActionButton("Save", x: panelX + 90, y: y, width: 70, action: #selector(savePreset(_:)))
        let loadBtn = makeActionButton("Load", x: panelX + 165, y: y, width: 70, action: #selector(loadPreset(_:)))
        cv.addSubview(resetBtn)
        cv.addSubview(saveBtn)
        cv.addSubview(loadBtn)

        y -= 30
        let exportICC = makeActionButton("Export ICC", x: panelX, y: y, width: 110, action: #selector(exportICCAction(_:)))
        let exportCube = makeActionButton("Export .cube", x: panelX + 115, y: y, width: 110, action: #selector(exportCubeAction(_:)))
        cv.addSubview(exportICC)
        cv.addSubview(exportCube)

        y -= 30
        let testBtn = makeActionButton("Test Patterns", x: panelX, y: y, width: 130, action: #selector(showTestPatterns(_:)))
        cv.addSubview(testBtn)

        // Separator
        y -= 16
        let sep5 = NSBox(frame: NSRect(x: panelX, y: y, width: panelW, height: 1))
        sep5.boxType = .separator
        cv.addSubview(sep5)

        // Cross-Display Calibration section
        y -= 24
        let calHeader = makeLabel("Cross-Display Calibration", x: panelX, y: y, width: panelW)
        calHeader.font = NSFont.boldSystemFont(ofSize: 11)
        cv.addSubview(calHeader)

        // Reference Display selector
        y -= 28
        let refLabel = makeLabel("Reference:", x: panelX, y: y + 2, width: 70)
        refLabel.font = NSFont.systemFont(ofSize: 10)
        cv.addSubview(refLabel)

        referenceDisplayPopup = NSPopUpButton(frame: NSRect(x: panelX + 72, y: y, width: panelW - 72, height: 24))
        cv.addSubview(referenceDisplayPopup)
        populateReferenceDisplays()

        // Match Color + Quick Match buttons
        y -= 28
        matchColorButton = makeActionButton("Match Color", x: panelX, y: y, width: 100, action: #selector(matchColorAction(_:)))
        quickMatchButton = makeActionButton("Quick Match", x: panelX + 105, y: y, width: 100, action: #selector(quickMatchAction(_:)))
        cv.addSubview(matchColorButton)
        cv.addSubview(quickMatchButton)

        // Done Matching button
        y -= 28
        doneMatchingButton = makeActionButton("Done Matching", x: panelX, y: y, width: 120, action: #selector(doneMatchingAction(_:)))
        doneMatchingButton.isEnabled = false
        cv.addSubview(doneMatchingButton)

        // Status label
        y -= 18
        colorMatchStatusLabel = makeLabel("Ready", x: panelX, y: y, width: panelW)
        colorMatchStatusLabel.font = NSFont.systemFont(ofSize: 9)
        colorMatchStatusLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
        cv.addSubview(colorMatchStatusLabel)

        // Pairs count label
        y -= 14
        colorMatchCountLabel = makeLabel("Pairs matched: 0", x: panelX, y: y, width: panelW)
        colorMatchCountLabel.font = NSFont.systemFont(ofSize: 9)
        colorMatchCountLabel.textColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)
        cv.addSubview(colorMatchCountLabel)

        // Separator
        y -= 14
        let sep6 = NSBox(frame: NSRect(x: panelX, y: y, width: panelW, height: 1))
        sep6.boxType = .separator
        cv.addSubview(sep6)

        // Target Gamma section
        y -= 22
        let gammaHeader = makeLabel("Target Gamma", x: panelX, y: y, width: 100)
        gammaHeader.font = NSFont.boldSystemFont(ofSize: 11)
        cv.addSubview(gammaHeader)

        y -= 24
        let gLabel = makeLabel("Gamma:", x: panelX, y: y + 2, width: 48)
        gLabel.font = NSFont.systemFont(ofSize: 10)
        cv.addSubview(gLabel)

        gammaSlider = NSSlider(frame: NSRect(x: panelX + 50, y: y, width: panelW - 110, height: 20))
        gammaSlider.minValue = 1.0
        gammaSlider.maxValue = 3.0
        gammaSlider.doubleValue = 2.2
        gammaSlider.isContinuous = true
        gammaSlider.target = self
        gammaSlider.action = #selector(gammaSliderChanged(_:))
        cv.addSubview(gammaSlider)

        gammaLabel = makeLabel("2.20", x: panelX + panelW - 55, y: y + 2, width: 60)
        gammaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        cv.addSubview(gammaLabel)
    }

    func buildTonalSlidersForChannel(_ ch: CurveChannel) {
        let sliderHeight: CGFloat = 160
        let containerW = tonalSliderContainer.frame.width
        let bandCount = 12
        let spacing = containerW / CGFloat(bandCount)

        var sliders: [NSSlider] = []
        var labels: [NSTextField] = []

        for band in 0..<bandCount {
            let x = CGFloat(band) * spacing + spacing / 2 - 15

            // Value label (top)
            let valLabel = NSTextField(frame: NSRect(x: x - 5, y: sliderHeight + 30, width: 40, height: 14))
            valLabel.stringValue = "0.00"
            valLabel.isEditable = false
            valLabel.isBordered = false
            valLabel.drawsBackground = false
            valLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)
            valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            valLabel.alignment = .center
            valLabel.tag = ch.rawValue * 100 + band
            tonalSliderContainer.addSubview(valLabel)
            labels.append(valLabel)

            // Vertical slider
            let slider = NSSlider(frame: NSRect(x: x, y: 30, width: 30, height: sliderHeight))
            slider.isVertical = true
            slider.minValue = -1.0
            slider.maxValue = 1.0
            slider.doubleValue = 0.0
            slider.isContinuous = true
            slider.tag = ch.rawValue * 100 + band
            slider.target = self
            slider.action = #selector(tonalEQSliderChanged(_:))
            tonalSliderContainer.addSubview(slider)
            sliders.append(slider)

            // Band label (bottom)
            let bandLabel = NSTextField(frame: NSRect(x: x - 10, y: 8, width: 50, height: 14))
            bandLabel.stringValue = tonalBandLabels[band]
            bandLabel.isEditable = false
            bandLabel.isBordered = false
            bandLabel.drawsBackground = false
            bandLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
            bandLabel.font = NSFont.systemFont(ofSize: 8)
            bandLabel.alignment = .center
            bandLabel.tag = ch.rawValue * 100 + band + 1000 // unique tag for band labels
            tonalSliderContainer.addSubview(bandLabel)
        }

        tonalEQSliders[ch.rawValue] = sliders
        tonalEQLabels[ch.rawValue] = labels
    }

    func showTonalSlidersForChannel(_ ch: CurveChannel) {
        // Hide all, show selected
        for subview in tonalSliderContainer.subviews {
            let baseChannel = subview.tag / 100
            let isBandLabel = subview.tag >= 1000
            if isBandLabel {
                let adjustedTag = subview.tag - 1000
                let labelChannel = adjustedTag / 100
                subview.isHidden = (labelChannel != ch.rawValue)
            } else {
                subview.isHidden = (baseChannel != ch.rawValue)
            }
        }
    }

    // MARK: - Bottom Bar (Tonal EQ)

    func buildBottomBar(_ cv: NSView) {
        let eqPanelHeight: CGFloat = 240
        let panelX: CGFloat = 15
        let y: CGFloat = eqPanelHeight + 10

        // Tonal EQ header + channel tabs
        let header = makeLabel("Tonal EQ", x: panelX, y: y + 4, width: 80)
        header.font = NSFont.boldSystemFont(ofSize: 12)
        cv.addSubview(header)

        var tabX: CGFloat = panelX + 80
        for ch in CurveChannel.allCases {
            let btn = makeTabButton(ch, x: tabX, y: y, tag: 100 + ch.rawValue)
            btn.target = self
            btn.action = #selector(tonalChannelTabClicked(_:))
            cv.addSubview(btn)
            tonalChannelButtons.append(btn)
            tabX += btn.frame.width + 2
        }
        updateTonalTabHighlight()

        // Container for tonal EQ sliders (full width)
        let containerY: CGFloat = 10
        tonalSliderContainer = NSView(frame: NSRect(x: panelX, y: containerY,
                                                     width: windowWidth - panelX * 2, height: eqPanelHeight))
        tonalSliderContainer.wantsLayer = true
        cv.addSubview(tonalSliderContainer)

        // Build all channel slider sets
        for ch in CurveChannel.allCases {
            buildTonalSlidersForChannel(ch)
        }
        showTonalSlidersForChannel(.master)
    }

    // MARK: - Display Management

    func populateDisplays() {
        displayPopup.removeAllItems()
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount)

        displayIDs = []
        var selectedIndex = 0
        for i in 0..<Int(displayCount) {
            let did = onlineDisplays[i]
            displayIDs.append(did)
            let w = CGDisplayPixelsWide(did)
            let h = CGDisplayPixelsHigh(did)
            let isMain = CGDisplayIsMain(did) != 0
            var name = "\(w)x\(h)"
            if isMain { name += " (Main)" }
            if w == 2560 && h == 1600 {
                name = "Cinema HD \(w)x\(h)"
                selectedIndex = i
            }
            displayPopup.addItem(withTitle: name)
        }
        if displayIDs.count > selectedIndex {
            displayPopup.selectItem(at: selectedIndex)
        }
    }

    func populateReferenceDisplays() {
        referenceDisplayPopup.removeAllItems()
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount)

        referenceDisplayIDs = []
        var selectedIndex = 0
        for i in 0..<Int(displayCount) {
            let did = onlineDisplays[i]
            referenceDisplayIDs.append(did)
            let w = CGDisplayPixelsWide(did)
            let h = CGDisplayPixelsHigh(did)
            let isMain = CGDisplayIsMain(did) != 0
            var name = "\(w)x\(h)"
            if isMain { name += " (Main)" }
            // Default to the non-Cinema HD display as reference (the Samsung or main display)
            if !(w == 2560 && h == 1600) {
                selectedIndex = i
            }
            referenceDisplayPopup.addItem(withTitle: name)
        }
        if referenceDisplayIDs.count > selectedIndex {
            referenceDisplayPopup.selectItem(at: selectedIndex)
        }
    }

    var referenceDisplayID: CGDirectDisplayID {
        let idx = referenceDisplayPopup.indexOfSelectedItem
        if idx >= 0 && idx < referenceDisplayIDs.count { return referenceDisplayIDs[idx] }
        return CGMainDisplayID()
    }

    var selectedDisplayID: CGDirectDisplayID {
        let idx = displayPopup.indexOfSelectedItem
        if idx >= 0 && idx < displayIDs.count { return displayIDs[idx] }
        return CGMainDisplayID()
    }

    @objc func displayChanged(_ sender: Any?) {
        // When user explicitly switches display target, restore old display and lock new one
        if userHasInteracted && targetDisplayID != 0 {
            CGDisplayRestoreColorSyncSettings()
        }
        targetDisplayID = selectedDisplayID
        if userHasInteracted && previewOn {
            applyLUT()
        }
    }

    // MARK: - Channel Switching (Curves)

    @objc func channelTabClicked(_ sender: NSButton) {
        curves[currentChannel.rawValue] = curveView.points
        guard let ch = CurveChannel(rawValue: sender.tag) else { return }
        currentChannel = ch
        curveView.channel = ch
        curveView.points = curves[ch.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        curveView.needsDisplay = true
        updateCurveTabHighlight()
    }

    func updateCurveTabHighlight() {
        for btn in channelButtons {
            btn.wantsLayer = true
            if btn.tag == currentChannel.rawValue {
                btn.layer?.backgroundColor = NSColor(calibratedWhite: 0.38, alpha: 1.0).cgColor
            } else {
                btn.layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor
            }
        }
    }

    // MARK: - Channel Switching (Tonal EQ)

    @objc func tonalChannelTabClicked(_ sender: NSButton) {
        let chRaw = sender.tag - 100
        guard let ch = CurveChannel(rawValue: chRaw) else { return }
        tonalEQChannel = ch
        showTonalSlidersForChannel(ch)
        updateTonalTabHighlight()
    }

    func updateTonalTabHighlight() {
        for btn in tonalChannelButtons {
            btn.wantsLayer = true
            if btn.tag - 100 == tonalEQChannel.rawValue {
                btn.layer?.backgroundColor = NSColor(calibratedWhite: 0.38, alpha: 1.0).cgColor
            } else {
                btn.layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor
            }
        }
    }

    // MARK: - Curve Changed

    func curveDidChange() {
        userHasInteracted = true
        curves[currentChannel.rawValue] = curveView.points
        pushUndoState()
        applyLUTIfPreviewOn()
    }

    // MARK: - Tonal EQ Slider Changed

    @objc func tonalEQSliderChanged(_ sender: NSSlider) {
        userHasInteracted = true
        let chRaw = sender.tag / 100
        let band = sender.tag % 100
        tonalBands[chRaw]?[band] = sender.doubleValue

        // Update label
        if let labels = tonalEQLabels[chRaw], band < labels.count {
            labels[band].stringValue = String(format: "%.2f", sender.doubleValue)
        }

        pushUndoState()
        applyLUTIfPreviewOn()
    }

    // MARK: - White Point

    @objc func whitePointPreset(_ sender: NSButton) {
        userHasInteracted = true
        whitePointKelvin = Double(sender.tag)
        kelvinSlider.doubleValue = whitePointKelvin
        kelvinLabel.stringValue = String(format: "%.0fK", whitePointKelvin)
        pushUndoState()
        applyLUTIfPreviewOn()
    }

    @objc func kelvinSliderChanged(_ sender: NSSlider) {
        userHasInteracted = true
        whitePointKelvin = sender.doubleValue
        kelvinLabel.stringValue = String(format: "%.0fK", whitePointKelvin)
        pushUndoState()
        applyLUTIfPreviewOn()
    }

    // MARK: - Preview Toggle

    @objc func togglePreview(_ sender: Any?) {
        previewOn = !previewOn
        if previewOn {
            previewButton.title = "Preview ON"
            liveIndicator.stringValue = "LIVE"
            liveIndicator.textColor = NSColor(calibratedRed: 0.2, green: 0.9, blue: 0.2, alpha: 1.0)
            if userHasInteracted {
                applyLUT()
            }
        } else {
            previewButton.title = "Preview OFF"
            liveIndicator.stringValue = "OFF"
            liveIndicator.textColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)
            // Apply identity LUT to target display only
            var identity = (0..<256).map { Float($0) / 255.0 }
            let did = targetDisplayID != 0 ? targetDisplayID : selectedDisplayID
            CGSetDisplayTransferByTable(did, 256, &identity, &identity, &identity)
            stopDithering()
        }
    }

    func applyLUTIfPreviewOn() {
        guard userHasInteracted else { return }
        // Auto-enable preview on first interaction
        if !previewOn {
            previewOn = true
            previewButton.title = "Preview ON"
            liveIndicator.stringValue = "LIVE"
            liveIndicator.textColor = NSColor(calibratedRed: 0.2, green: 0.9, blue: 0.2, alpha: 1.0)
        }
        applyLUT()
    }

    // MARK: - LUT Pipeline

    func computeFinalLUT() -> ([Float], [Float], [Float]) {
        curves[currentChannel.rawValue] = curveView.points

        // Step 1: Master curve
        let masterLUT = monotonicCubicInterpolation(
            points: curves[CurveChannel.master.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)

        // Step 2: Per-channel RGB
        let redLUT = monotonicCubicInterpolation(
            points: curves[CurveChannel.red.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let greenLUT = monotonicCubicInterpolation(
            points: curves[CurveChannel.green.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let blueLUT = monotonicCubicInterpolation(
            points: curves[CurveChannel.blue.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)

        // Step 3: CMYK
        let cyanLUT = monotonicCubicInterpolation(
            points: curves[CurveChannel.cyan.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let magentaLUT = monotonicCubicInterpolation(
            points: curves[CurveChannel.magenta.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let yellowLUT = monotonicCubicInterpolation(
            points: curves[CurveChannel.yellow.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let blackLUT = monotonicCubicInterpolation(
            points: curves[CurveChannel.black.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)

        // Bradford white point gains
        let (wpR, wpG, wpB) = bradfordGains(sourceKelvin: 6504, destKelvin: whitePointKelvin)

        var rTable = [Float](repeating: 0, count: 256)
        var gTable = [Float](repeating: 0, count: 256)
        var bTable = [Float](repeating: 0, count: 256)

        for i in 0..<256 {
            let t = CGFloat(i) / 255.0

            // Step 1: Master
            let afterMaster = masterLUT[i]

            // Step 2: Per-channel RGB
            let rIdx = min(255, max(0, Int(afterMaster * 255.0)))
            var r = redLUT[rIdx]
            var g = greenLUT[rIdx]
            var b = blueLUT[rIdx]

            // Step 3: CMYK deltas
            let identity = t
            let cDelta = cyanLUT[i] - identity
            let mDelta = magentaLUT[i] - identity
            let yDelta = yellowLUT[i] - identity
            let kDelta = blackLUT[i] - identity

            r -= (cDelta + kDelta)
            g -= (mDelta + kDelta)
            b -= (yDelta + kDelta)

            // Step 4: Tonal EQ - apply 12-band Gaussian brightness per channel
            r = applyTonalEQ(r, originalT: t, channelRaw: CurveChannel.master.rawValue)
            r = applyTonalEQ(r, originalT: t, channelRaw: CurveChannel.red.rawValue)

            g = applyTonalEQ(g, originalT: t, channelRaw: CurveChannel.master.rawValue)
            g = applyTonalEQ(g, originalT: t, channelRaw: CurveChannel.green.rawValue)

            b = applyTonalEQ(b, originalT: t, channelRaw: CurveChannel.master.rawValue)
            b = applyTonalEQ(b, originalT: t, channelRaw: CurveChannel.blue.rawValue)

            // CMYK tonal EQ contributions
            let cEQ = computeTonalEQDelta(t, channelRaw: CurveChannel.cyan.rawValue)
            let mEQ = computeTonalEQDelta(t, channelRaw: CurveChannel.magenta.rawValue)
            let yEQ = computeTonalEQDelta(t, channelRaw: CurveChannel.yellow.rawValue)
            let kEQ = computeTonalEQDelta(t, channelRaw: CurveChannel.black.rawValue)

            r -= (cEQ + kEQ)
            g -= (mEQ + kEQ)
            b -= (yEQ + kEQ)

            // Step 5: White point (Bradford gains)
            r *= CGFloat(wpR)
            g *= CGFloat(wpG)
            b *= CGFloat(wpB)

            // Step 6: Target gamma correction (relative to standard 2.2)
            if abs(targetGamma - 2.2) > 0.001 {
                let gammaExp = CGFloat(targetGamma / 2.2)
                if r > 0 { r = pow(r, gammaExp) }
                if g > 0 { g = pow(g, gammaExp) }
                if b > 0 { b = pow(b, gammaExp) }
            }

            // Step 7: Clamp 0-1
            r = max(0, min(1, r))
            g = max(0, min(1, g))
            b = max(0, min(1, b))

            // Step 8: Safety clamp min 0.03 for indices > 0
            if i > 0 {
                r = max(0.03, r)
                g = max(0.03, g)
                b = max(0.03, b)
            }

            rTable[i] = Float(r)
            gTable[i] = Float(g)
            bTable[i] = Float(b)
        }

        return (rTable, gTable, bTable)
    }

    func applyTonalEQ(_ value: CGFloat, originalT: CGFloat, channelRaw: Int) -> CGFloat {
        guard let bands = tonalBands[channelRaw] else { return value }
        var v = value
        for band in 0..<12 {
            let center = CGFloat(tonalBandCenters[band])
            let sigma = CGFloat(tonalBandSigma)
            let weight = gaussianWeight(originalT, center: center, sigma: sigma)
            v += CGFloat(bands[band]) * weight * 0.5
        }
        return v
    }

    func computeTonalEQDelta(_ t: CGFloat, channelRaw: Int) -> CGFloat {
        guard let bands = tonalBands[channelRaw] else { return 0 }
        var delta: CGFloat = 0
        for band in 0..<12 {
            let center = CGFloat(tonalBandCenters[band])
            let sigma = CGFloat(tonalBandSigma)
            let weight = gaussianWeight(t, center: center, sigma: sigma)
            delta += CGFloat(bands[band]) * weight * 0.5
        }
        return delta
    }

    var targetDisplayID: CGDirectDisplayID = 0  // locked when user first interacts

    func applyLUT() {
        guard userHasInteracted else { return }

        // Lock the target display on first interaction — never change mid-session
        // This prevents accidentally sending gamma tables to the wrong display
        if targetDisplayID == 0 {
            targetDisplayID = selectedDisplayID
        }
        let did = targetDisplayID

        let (rTable, gTable, bTable) = computeFinalLUT()

        // SAFETY: reject if any channel peak < 0.1
        guard let rMax = rTable.max(), let gMax = gTable.max(), let bMax = bTable.max(),
              rMax >= 0.1, gMax >= 0.1, bMax >= 0.1 else {
            return
        }

        // SAFETY: clamp minimum to 0.03 for indices > 0
        var r = rTable.enumerated().map { $0.offset == 0 ? $0.element : max(0.03, $0.element) }
        var g = gTable.enumerated().map { $0.offset == 0 ? $0.element : max(0.03, $0.element) }
        var b = bTable.enumerated().map { $0.offset == 0 ? $0.element : max(0.03, $0.element) }

        // Store for temporal dithering
        lastRTable = r
        lastGTable = g
        lastBTable = b

        if temporalDitheringEnabled && previewOn {
            startDithering()
        } else {
            CGSetDisplayTransferByTable(did, 256, &r, &g, &b)
        }
    }

    // MARK: - Temporal Dithering (CVDisplayLink)

    func startDithering() {
        guard displayLink == nil else { return }

        var dl: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&dl)
        guard let link = dl else { return }

        let controller = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let ptr = userInfo else { return kCVReturnSuccess }
            let ctrl = Unmanaged<DisplayTunerController>.fromOpaque(ptr).takeUnretainedValue()
            ctrl.ditheringCallback()
            return kCVReturnSuccess
        }, controller)

        CVDisplayLinkStart(link)
        displayLink = link
    }

    func stopDithering() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    func ditheringCallback() {
        ditheringFrame += 1
        let useFloor = (ditheringFrame % 2 == 0)

        guard targetDisplayID != 0 else { return }  // SAFETY: don't dither until display is locked
        let did = targetDisplayID
        var r = lastRTable
        var g = lastGTable
        var b = lastBTable

        if !useFloor {
            // Ceil variant: add 0.5/255 to fractional entries
            let step = Float(0.5 / 255.0)
            for i in 0..<256 {
                r[i] = min(1.0, r[i] + step)
                g[i] = min(1.0, g[i] + step)
                b[i] = min(1.0, b[i] + step)
            }
        }

        CGSetDisplayTransferByTable(did, 256, &r, &g, &b)
    }

    @objc func toggleDithering(_ sender: NSButton) {
        temporalDitheringEnabled = (sender.state == .on)
        if temporalDitheringEnabled && previewOn && userHasInteracted {
            startDithering()
        } else {
            stopDithering()
            if previewOn && userHasInteracted {
                applyLUT()
            }
        }
    }

    // MARK: - Undo/Redo

    func captureState() -> UndoState {
        curves[currentChannel.rawValue] = curveView.points
        return UndoState(
            curves: curves,
            tonalBands: tonalBands,
            whitePointKelvin: whitePointKelvin,
            targetGamma: targetGamma
        )
    }

    func restoreState(_ state: UndoState) {
        curves = state.curves
        tonalBands = state.tonalBands
        whitePointKelvin = state.whitePointKelvin
        targetGamma = state.targetGamma

        // Refresh UI
        curveView.points = curves[currentChannel.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        curveView.needsDisplay = true

        kelvinSlider.doubleValue = whitePointKelvin
        kelvinLabel.stringValue = String(format: "%.0fK", whitePointKelvin)

        gammaSlider.doubleValue = targetGamma
        gammaLabel.stringValue = String(format: "%.2f", targetGamma)

        // Refresh tonal EQ sliders
        for ch in CurveChannel.allCases {
            if let sliders = tonalEQSliders[ch.rawValue], let bands = tonalBands[ch.rawValue] {
                for (i, slider) in sliders.enumerated() {
                    slider.doubleValue = bands[i]
                }
            }
            if let labels = tonalEQLabels[ch.rawValue], let bands = tonalBands[ch.rawValue] {
                for (i, label) in labels.enumerated() {
                    label.stringValue = String(format: "%.2f", bands[i])
                }
            }
        }

        applyLUTIfPreviewOn()
    }

    func pushUndoState() {
        let state = captureState()
        undoStack.append(state)
        if undoStack.count > maxUndoStates {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    @objc func undoAction(_ sender: Any?) {
        guard undoStack.count > 1 else { return }
        let current = undoStack.removeLast()
        redoStack.append(current)
        if let prev = undoStack.last {
            restoreState(prev)
        }
    }

    @objc func redoAction(_ sender: Any?) {
        guard let state = redoStack.popLast() else { return }
        undoStack.append(state)
        restoreState(state)
    }

    // MARK: - Eyedropper

    @objc func pickBlackPoint(_ sender: Any?) {
        if #available(macOS 10.15, *) {
            let sampler = NSColorSampler()
            sampler.show { [weak self] selectedColor in
                guard let color = selectedColor, let self = self else { return }
                self.userHasInteracted = true
                let rgb = color.usingColorSpace(.sRGB) ?? color
                let brightness = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                self.setBlackEndpoint(for: .red, value: CGFloat(brightness))
                self.setBlackEndpoint(for: .green, value: CGFloat(brightness))
                self.setBlackEndpoint(for: .blue, value: CGFloat(brightness))
                self.refreshCurveView()
                self.pushUndoState()
                self.applyLUTIfPreviewOn()
            }
        }
    }

    @objc func pickWhitePoint(_ sender: Any?) {
        if #available(macOS 10.15, *) {
            let sampler = NSColorSampler()
            sampler.show { [weak self] selectedColor in
                guard let color = selectedColor, let self = self else { return }
                self.userHasInteracted = true
                let rgb = color.usingColorSpace(.sRGB) ?? color
                let brightness = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                self.setWhiteEndpoint(for: .red, value: CGFloat(brightness))
                self.setWhiteEndpoint(for: .green, value: CGFloat(brightness))
                self.setWhiteEndpoint(for: .blue, value: CGFloat(brightness))
                self.refreshCurveView()
                self.pushUndoState()
                self.applyLUTIfPreviewOn()
            }
        }
    }

    @objc func pickGrayPoint(_ sender: Any?) {
        if #available(macOS 10.15, *) {
            let sampler = NSColorSampler()
            sampler.show { [weak self] selectedColor in
                guard let color = selectedColor, let self = self else { return }
                self.userHasInteracted = true
                let rgb = color.usingColorSpace(.sRGB) ?? color
                let r = CGFloat(rgb.redComponent)
                let g = CGFloat(rgb.greenComponent)
                let b = CGFloat(rgb.blueComponent)
                let avg = (r + g + b) / 3.0
                self.neutralizeAtBrightness(channel: .red, actual: r, target: avg)
                self.neutralizeAtBrightness(channel: .green, actual: g, target: avg)
                self.neutralizeAtBrightness(channel: .blue, actual: b, target: avg)
                self.refreshCurveView()
                self.pushUndoState()
                self.applyLUTIfPreviewOn()
            }
        }
    }

    func setBlackEndpoint(for channel: CurveChannel, value: CGFloat) {
        var pts = curves[channel.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        if let minIdx = pts.indices.min(by: { pts[$0].x < pts[$1].x }) {
            pts[minIdx] = CurvePoint(x: value, y: 0)
        }
        pts.sort { $0.x < $1.x }
        curves[channel.rawValue] = pts
    }

    func setWhiteEndpoint(for channel: CurveChannel, value: CGFloat) {
        var pts = curves[channel.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        if let maxIdx = pts.indices.max(by: { pts[$0].x < pts[$1].x }) {
            pts[maxIdx] = CurvePoint(x: value, y: 1)
        }
        pts.sort { $0.x < $1.x }
        curves[channel.rawValue] = pts
    }

    func neutralizeAtBrightness(channel: CurveChannel, actual: CGFloat, target: CGFloat) {
        var pts = curves[channel.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        pts.removeAll { abs($0.x - actual) < 0.02 && $0.x > 0.01 && $0.x < 0.99 }
        pts.append(CurvePoint(x: actual, y: target))
        pts.sort { $0.x < $1.x }
        curves[channel.rawValue] = pts
    }

    func refreshCurveView() {
        curveView.points = curves[currentChannel.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        curveView.needsDisplay = true
    }

    // MARK: - Cross-Display Calibration (v4)

    @objc func matchColorAction(_ sender: Any?) {
        if #available(macOS 10.15, *) {
            colorMatchStep = 1
            colorMatchStatusLabel.stringValue = "Step 1: Pick a color on the TARGET display..."
            colorMatchStatusLabel.textColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.3, alpha: 1.0)
            doneMatchingButton.isEnabled = true
            matchColorButton.isEnabled = false

            let sampler = NSColorSampler()
            sampler.show { [weak self] selectedColor in
                guard let self = self else { return }
                guard let color = selectedColor else {
                    self.colorMatchStep = 0
                    self.colorMatchStatusLabel.stringValue = "Cancelled."
                    self.colorMatchStatusLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
                    self.matchColorButton.isEnabled = true
                    return
                }
                let rgb = color.usingColorSpace(.sRGB) ?? color
                self.pendingSourceColor = rgb
                self.colorMatchStep = 2
                self.colorMatchStatusLabel.stringValue = "Step 2: Pick the SAME color on the REFERENCE display..."
                self.colorMatchStatusLabel.textColor = NSColor(calibratedRed: 0.3, green: 0.8, blue: 1.0, alpha: 1.0)

                let sampler2 = NSColorSampler()
                sampler2.show { [weak self] selectedColor2 in
                    guard let self = self else { return }
                    guard let color2 = selectedColor2, let srcColor = self.pendingSourceColor else {
                        self.colorMatchStep = 0
                        self.colorMatchStatusLabel.stringValue = "Cancelled."
                        self.colorMatchStatusLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
                        self.matchColorButton.isEnabled = true
                        return
                    }
                    let tgtRGB = color2.usingColorSpace(.sRGB) ?? color2

                    // Record the pair
                    self.colorMatchPairs.append((source: srcColor, target: tgtRGB))

                    // Apply curve points from this match
                    self.applyCurvePointsFromColorMatch(source: srcColor, target: tgtRGB)

                    let srcR = String(format: "%.2f", srcColor.redComponent)
                    let srcG = String(format: "%.2f", srcColor.greenComponent)
                    let srcB = String(format: "%.2f", srcColor.blueComponent)
                    let tgtR = String(format: "%.2f", tgtRGB.redComponent)
                    let tgtG = String(format: "%.2f", tgtRGB.greenComponent)
                    let tgtB = String(format: "%.2f", tgtRGB.blueComponent)

                    self.colorMatchStatusLabel.stringValue = "Mapped: R(\(srcR)->\(tgtR)) G(\(srcG)->\(tgtG)) B(\(srcB)->\(tgtB)). Pick another or Done."
                    self.colorMatchStatusLabel.textColor = NSColor(calibratedRed: 0.2, green: 0.9, blue: 0.2, alpha: 1.0)
                    self.colorMatchCountLabel.stringValue = "Pairs matched: \(self.colorMatchPairs.count)"
                    self.colorMatchStep = 0
                    self.matchColorButton.isEnabled = true

                    self.userHasInteracted = true
                    self.refreshCurveView()
                    self.pushUndoState()
                    self.applyLUTIfPreviewOn()
                }
            }
        }
    }

    func applyCurvePointsFromColorMatch(source: NSColor, target: NSColor) {
        // For each channel, add a control point:
        // x = source channel value (where on the curve this correction applies)
        // y = target channel value (what it should map to)
        let channels: [(CurveChannel, CGFloat, CGFloat)] = [
            (.red, source.redComponent, target.redComponent),
            (.green, source.greenComponent, target.greenComponent),
            (.blue, source.blueComponent, target.blueComponent),
        ]

        for (channel, srcVal, tgtVal) in channels {
            var pts = curves[channel.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
            // Remove any existing point very close to this x position (within 0.02)
            pts.removeAll { abs($0.x - srcVal) < 0.02 && $0.x > 0.01 && $0.x < 0.99 }
            // Add the new correction point
            pts.append(CurvePoint(x: srcVal, y: tgtVal))
            pts.sort { $0.x < $1.x }
            curves[channel.rawValue] = pts
        }
    }

    @objc func quickMatchAction(_ sender: Any?) {
        // Automated profile-math calibration using ICC profile data
        // Get the reference display's color space TRC
        let refID = referenceDisplayID
        let refColorSpace = CGDisplayCopyColorSpace(refID)

        // Try to extract ICC profile data for gamma information
        var refGamma: Double = 2.2 // default assumption: sRGB gamma

        if let iccData = refColorSpace.iccData as Data? {
            // Try to parse rTRC tag to extract gamma
            if let parsedGamma = extractGammaFromICCData(iccData) {
                refGamma = parsedGamma
            }
        }

        // For the target display (Cinema HD on Raw Passthrough), assume gamma ~1.0
        // The correction needed: apply pow(x, refGamma) to make it look like the reference
        // But since we work with curve points, we sample 21 points

        let testPoints = 21
        for channel in [CurveChannel.red, CurveChannel.green, CurveChannel.blue] {
            var pts: [CurvePoint] = []
            for i in 0..<testPoints {
                let x = CGFloat(i) / CGFloat(testPoints - 1)
                // What the reference display shows at input x:
                // refOutput = pow(x, refGamma) conceptually
                // What the raw passthrough shows: just x (linear)
                // Correction: we want output y such that the target display
                // shows the same as the reference at input x
                // If target is linear (gamma 1.0), we need y = pow(x, refGamma / 1.0) = pow(x, refGamma)
                // But this is the full correction; typically we want y = pow(x, refGamma / 2.2)
                // since macOS may already apply some gamma
                // Use the simpler approach: assume raw passthrough needs sRGB gamma applied
                let y = CGFloat(pow(Double(x), refGamma / 2.2))
                pts.append(CurvePoint(x: x, y: y))
            }
            curves[channel.rawValue] = pts
        }

        colorMatchStatusLabel.stringValue = "Quick Match applied (ref gamma: \(String(format: "%.2f", refGamma)))"
        colorMatchStatusLabel.textColor = NSColor(calibratedRed: 0.2, green: 0.9, blue: 0.2, alpha: 1.0)

        userHasInteracted = true
        refreshCurveView()
        pushUndoState()
        applyLUTIfPreviewOn()
    }

    func extractGammaFromICCData(_ data: Data) -> Double? {
        // Minimal ICC parser: look for rTRC tag to extract a single gamma value
        guard data.count > 132 else { return nil }

        // Read tag count at offset 128
        let tagCount = readUInt32(data, offset: 128)
        guard tagCount > 0, tagCount < 100 else { return nil }

        // Search for rTRC tag
        for i in 0..<Int(tagCount) {
            let entryOffset = 132 + i * 12
            guard entryOffset + 12 <= data.count else { break }

            let sig = String(data: data[entryOffset..<entryOffset+4], encoding: .ascii) ?? ""
            if sig == "rTRC" {
                let tagOffset = Int(readUInt32(data, offset: entryOffset + 4))
                let tagSize = Int(readUInt32(data, offset: entryOffset + 8))
                guard tagOffset + tagSize <= data.count else { return nil }

                // Check if it's a 'curv' type
                let typeSig = String(data: data[tagOffset..<tagOffset+4], encoding: .ascii) ?? ""
                if typeSig == "curv" {
                    let curveCount = Int(readUInt32(data, offset: tagOffset + 8))
                    if curveCount == 0 {
                        // Identity (gamma 1.0)
                        return 1.0
                    } else if curveCount == 1 {
                        // Single u8Fixed8Number gamma value
                        let gammaRaw = readUInt16(data, offset: tagOffset + 12)
                        return Double(gammaRaw) / 256.0
                    }
                    // Multi-point TRC: approximate gamma from the curve
                    // Sample the midpoint to estimate gamma
                    if curveCount >= 2 {
                        let midIdx = curveCount / 2
                        let midOffset = tagOffset + 12 + midIdx * 2
                        guard midOffset + 2 <= data.count else { return nil }
                        let midVal = Double(readUInt16(data, offset: midOffset)) / 65535.0
                        let midInput = Double(midIdx) / Double(curveCount - 1)
                        // gamma = log(output) / log(input)
                        if midInput > 0.01 && midInput < 0.99 && midVal > 0.001 {
                            let estimatedGamma = log(midVal) / log(midInput)
                            if estimatedGamma > 0.5 && estimatedGamma < 5.0 {
                                return estimatedGamma
                            }
                        }
                    }
                }
                // 'para' parametric curve type
                if typeSig == "para" {
                    let funcType = Int(readUInt16(data, offset: tagOffset + 8))
                    if funcType == 0 {
                        // Simple gamma: Y = X^g
                        let gammaFixed = readS15Fixed16(data, offset: tagOffset + 12)
                        if gammaFixed > 0.5 && gammaFixed < 5.0 {
                            return gammaFixed
                        }
                    }
                }
            }
        }
        return nil
    }

    func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let bytes = [UInt8](data[offset..<offset+4])
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let bytes = [UInt8](data[offset..<offset+2])
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    func readS15Fixed16(_ data: Data, offset: Int) -> Double {
        guard offset + 4 <= data.count else { return 0 }
        let bytes = [UInt8](data[offset..<offset+4])
        let raw = Int32(bytes[0]) << 24 | Int32(bytes[1]) << 16 | Int32(bytes[2]) << 8 | Int32(bytes[3])
        return Double(raw) / 65536.0
    }

    @objc func doneMatchingAction(_ sender: Any?) {
        colorMatchStep = 0
        doneMatchingButton.isEnabled = false
        if colorMatchPairs.isEmpty {
            colorMatchStatusLabel.stringValue = "No color pairs recorded."
        } else {
            colorMatchStatusLabel.stringValue = "Calibration complete: \(colorMatchPairs.count) pair(s) applied."
        }
        colorMatchStatusLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
        matchColorButton.isEnabled = true
    }

    // MARK: - Target Gamma

    @objc func gammaSliderChanged(_ sender: NSSlider) {
        userHasInteracted = true
        targetGamma = sender.doubleValue
        gammaLabel.stringValue = String(format: "%.2f", targetGamma)
        pushUndoState()
        applyLUTIfPreviewOn()
    }

    // MARK: - Reset

    @objc func resetAll(_ sender: Any?) {
        initCurves()
        initTonalBands()
        whitePointKelvin = 6500
        currentChannel = .master
        curveView.channel = .master
        curveView.points = curves[CurveChannel.master.rawValue]!
        curveView.needsDisplay = true
        updateCurveTabHighlight()

        kelvinSlider.doubleValue = 6500
        kelvinLabel.stringValue = "6500K"

        for ch in CurveChannel.allCases {
            if let sliders = tonalEQSliders[ch.rawValue] {
                for s in sliders { s.doubleValue = 0 }
            }
            if let labels = tonalEQLabels[ch.rawValue] {
                for l in labels { l.stringValue = "0.00" }
            }
        }

        previewOn = false
        previewButton.title = "Preview OFF"
        liveIndicator.stringValue = "OFF"
        liveIndicator.textColor = NSColor(calibratedWhite: 0.5, alpha: 1.0)

        // Reset cross-display calibration state
        colorMatchPairs.removeAll()
        colorMatchStep = 0
        pendingSourceColor = nil
        colorMatchStatusLabel.stringValue = "Ready"
        colorMatchStatusLabel.textColor = NSColor(calibratedWhite: 0.6, alpha: 1.0)
        colorMatchCountLabel.stringValue = "Pairs matched: 0"
        doneMatchingButton.isEnabled = false
        matchColorButton.isEnabled = true

        // Reset gamma
        targetGamma = 2.2
        gammaSlider.doubleValue = 2.2
        gammaLabel.stringValue = "2.20"

        stopDithering()
        CGDisplayRestoreColorSyncSettings()

        undoStack.removeAll()
        redoStack.removeAll()
        pushUndoState()
    }

    // MARK: - Save/Load

    @objc func savePreset(_ sender: Any?) {
        curves[currentChannel.rawValue] = curveView.points

        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Enter a name for this preset:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = "my_preset"
        alert.accessoryView = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        var preset = PresetData()
        preset.curves = curves
        preset.tonalEQ.bands = tonalBands
        preset.whitePointKelvin = whitePointKelvin
        preset.previewOn = previewOn
        preset.targetGamma = targetGamma

        let presetsDir = NSString(string: "~/.config/displayctl/presets").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: presetsDir, withIntermediateDirectories: true)
        let filePath = (presetsDir as NSString).appendingPathComponent("\(name).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(preset) {
            try? data.write(to: URL(fileURLWithPath: filePath))
            let conf = NSAlert()
            conf.messageText = "Saved"
            conf.informativeText = "Preset saved to \(filePath)"
            conf.alertStyle = .informational
            conf.runModal()
        }
    }

    @objc func loadPreset(_ sender: Any?) {
        let openPanel = NSOpenPanel()
        openPanel.title = "Load Preset"
        openPanel.allowedContentTypes = [.json]
        let presetsDir = NSString(string: "~/.config/displayctl/presets").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: presetsDir, withIntermediateDirectories: true)
        openPanel.directoryURL = URL(fileURLWithPath: presetsDir)

        openPanel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self, response == .OK, let url = openPanel.url else { return }
            guard let data = try? Data(contentsOf: url) else { return }
            guard let preset = try? JSONDecoder().decode(PresetData.self, from: data) else { return }

            self.curves = preset.curves
            self.tonalBands = preset.tonalEQ.bands
            self.whitePointKelvin = preset.whitePointKelvin
            self.targetGamma = preset.targetGamma ?? 2.2

            self.refreshCurveView()
            self.kelvinSlider.doubleValue = self.whitePointKelvin
            self.kelvinLabel.stringValue = String(format: "%.0fK", self.whitePointKelvin)
            self.gammaSlider.doubleValue = self.targetGamma
            self.gammaLabel.stringValue = String(format: "%.2f", self.targetGamma)

            for ch in CurveChannel.allCases {
                if let sliders = self.tonalEQSliders[ch.rawValue],
                   let bands = self.tonalBands[ch.rawValue] {
                    for (i, slider) in sliders.enumerated() where i < bands.count {
                        slider.doubleValue = bands[i]
                    }
                }
                if let labels = self.tonalEQLabels[ch.rawValue],
                   let bands = self.tonalBands[ch.rawValue] {
                    for (i, label) in labels.enumerated() where i < bands.count {
                        label.stringValue = String(format: "%.2f", bands[i])
                    }
                }
            }

            self.userHasInteracted = true
            self.pushUndoState()
            self.applyLUTIfPreviewOn()
        }
    }

    // MARK: - Export ICC

    @objc func exportICCAction(_ sender: Any?) {
        curves[currentChannel.rawValue] = curveView.points

        let alert = NSAlert()
        alert.messageText = "Export ICC Profile"
        alert.informativeText = "Enter a name for the ICC profile:"
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = "DisplayTuner_Custom"
        alert.accessoryView = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let (rTable, gTable, bTable) = computeFinalLUT()

        // Validate LUT
        guard let rMax = rTable.max(), let gMax = gTable.max(), let bMax = bTable.max(),
              rMax >= 0.1, gMax >= 0.1, bMax >= 0.1 else {
            let errAlert = NSAlert()
            errAlert.messageText = "Validation Failed"
            errAlert.informativeText = "LUT has dangerously low peak values. Export aborted."
            errAlert.alertStyle = .critical
            errAlert.runModal()
            return
        }

        // Build ICC profile inline (minimal v2.4 with vcgt)
        let iccData = buildICCProfile(name: name, rTable: rTable, gTable: gTable, bTable: bTable)

        let profileDir = NSString(string: "~/Library/ColorSync/Profiles").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: profileDir, withIntermediateDirectories: true)
        let profilePath = (profileDir as NSString).appendingPathComponent("\(name).icc")

        do {
            try iccData.write(to: URL(fileURLWithPath: profilePath))
            let conf = NSAlert()
            conf.messageText = "ICC Profile Exported"
            conf.informativeText = "Saved to \(profilePath)\nSelect it in System Settings > Displays > Color."
            conf.alertStyle = .informational
            conf.runModal()
        } catch {
            let errAlert = NSAlert()
            errAlert.messageText = "Export Failed"
            errAlert.informativeText = error.localizedDescription
            errAlert.alertStyle = .critical
            errAlert.runModal()
        }
    }

    func buildICCProfile(name: String, rTable: [Float], gTable: [Float], bTable: [Float]) -> Data {
        var data = Data()

        func appendUInt32(_ val: UInt32) { var v = val.bigEndian; data.append(Data(bytes: &v, count: 4)) }
        func appendUInt16(_ val: UInt16) { var v = val.bigEndian; data.append(Data(bytes: &v, count: 2)) }
        func appendBytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        func appendString(_ s: String, length: Int) {
            let bytes = Array(s.utf8)
            for i in 0..<length {
                data.append(i < bytes.count ? bytes[i] : 0)
            }
        }
        func appendS15Fixed16(_ val: Double) {
            let fixed = Int32(val * 65536.0)
            var v = fixed.bigEndian
            data.append(Data(bytes: &v, count: 4))
        }

        // We'll build a minimal ICC v2 profile
        // Header: 128 bytes
        _ = data.count // header starts here
        appendUInt32(0) // placeholder for profile size
        appendString("appl", length: 4) // preferred CMM
        appendUInt32(0x02400000) // version 2.4.0
        appendString("mntr", length: 4) // device class: monitor
        appendString("RGB ", length: 4) // color space
        appendString("XYZ ", length: 4) // PCS
        // Date/time (12 bytes) - use current
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        appendUInt16(UInt16(comps.year ?? 2026))
        appendUInt16(UInt16(comps.month ?? 1))
        appendUInt16(UInt16(comps.day ?? 1))
        appendUInt16(UInt16(comps.hour ?? 0))
        appendUInt16(UInt16(comps.minute ?? 0))
        appendUInt16(UInt16(comps.second ?? 0))
        appendString("acsp", length: 4) // magic
        appendString("APPL", length: 4) // platform
        appendUInt32(0) // flags
        appendString("none", length: 4) // device manufacturer
        appendString("none", length: 4) // device model
        appendBytes([0,0,0,0,0,0,0,0]) // device attributes
        appendUInt32(0) // rendering intent (perceptual)
        // PCS illuminant (D50 XYZ)
        appendS15Fixed16(0.9642)
        appendS15Fixed16(1.0)
        appendS15Fixed16(0.8249)
        appendString("appl", length: 4) // creator
        // Profile ID (16 bytes of zeros)
        for _ in 0..<16 { data.append(0) }
        // Reserved (28 bytes)
        for _ in 0..<28 { data.append(0) }

        // Tag table
        let tagCount: UInt32 = 9 // desc, wtpt, rXYZ, gXYZ, bXYZ, rTRC, gTRC, bTRC, vcgt
        appendUInt32(tagCount)

        // We'll compute tag offsets after writing placeholders
        let tagTableStart = data.count
        // Each tag entry: 4 (sig) + 4 (offset) + 4 (size) = 12 bytes
        for _ in 0..<tagCount {
            appendUInt32(0); appendUInt32(0); appendUInt32(0)
        }

        // Helper to pad to 4-byte boundary
        func padTo4() {
            while data.count % 4 != 0 { data.append(0) }
        }

        // Tag: desc
        let descOffset = UInt32(data.count)
        appendString("desc", length: 4)
        appendUInt32(0) // reserved
        let nameBytes = Array(name.utf8)
        appendUInt32(UInt32(nameBytes.count + 1))
        data.append(contentsOf: nameBytes)
        data.append(0) // null terminator
        // Minimal: skip unicode and scriptcode
        appendUInt32(0) // unicode lang code
        appendUInt32(0) // unicode count
        appendUInt16(0) // scriptcode code
        data.append(UInt8(0)) // scriptcode count
        for _ in 0..<67 { data.append(0) } // scriptcode string (67 bytes)
        padTo4()
        let descSize = UInt32(data.count) - descOffset

        // Tag: wtpt (D65 adapted white point in PCS = D50)
        let wtptOffset = UInt32(data.count)
        appendString("XYZ ", length: 4)
        appendUInt32(0)
        appendS15Fixed16(0.9505)
        appendS15Fixed16(1.0)
        appendS15Fixed16(1.0890)
        padTo4()
        let wtptSize = UInt32(data.count) - wtptOffset

        // sRGB primaries (XYZ, D50 adapted)
        // rXYZ
        let rXYZOffset = UInt32(data.count)
        appendString("XYZ ", length: 4); appendUInt32(0)
        appendS15Fixed16(0.4360747); appendS15Fixed16(0.2225045); appendS15Fixed16(0.0139322)
        padTo4()
        let rXYZSize = UInt32(data.count) - rXYZOffset

        // gXYZ
        let gXYZOffset = UInt32(data.count)
        appendString("XYZ ", length: 4); appendUInt32(0)
        appendS15Fixed16(0.3850649); appendS15Fixed16(0.7168786); appendS15Fixed16(0.0971045)
        padTo4()
        let gXYZSize = UInt32(data.count) - gXYZOffset

        // bXYZ
        let bXYZOffset = UInt32(data.count)
        appendString("XYZ ", length: 4); appendUInt32(0)
        appendS15Fixed16(0.1430804); appendS15Fixed16(0.0606169); appendS15Fixed16(0.7141633)
        padTo4()
        let bXYZSize = UInt32(data.count) - bXYZOffset

        // TRC tags (256-entry curv)
        func writeTRC(_ table: [Float]) -> (UInt32, UInt32) {
            let offset = UInt32(data.count)
            appendString("curv", length: 4)
            appendUInt32(0) // reserved
            appendUInt32(256) // count
            for v in table {
                let u16 = UInt16(max(0, min(65535, Int(Double(v) * 65535.0))))
                appendUInt16(u16)
            }
            padTo4()
            return (offset, UInt32(data.count) - offset)
        }

        let (rTRCOffset, rTRCSize) = writeTRC(rTable)
        let (gTRCOffset, gTRCSize) = writeTRC(gTable)
        let (bTRCOffset, bTRCSize) = writeTRC(bTable)

        // vcgt tag
        let vcgtOffset = UInt32(data.count)
        appendString("vcgt", length: 4)
        appendUInt32(0) // reserved
        appendUInt32(0) // type 0 = table
        appendUInt16(3) // channels
        appendUInt16(256) // entry count
        appendUInt16(2) // entry size (bytes)
        for table in [rTable, gTable, bTable] {
            for v in table {
                let u16 = UInt16(max(0, min(65535, Int(Double(v) * 65535.0))))
                appendUInt16(u16)
            }
        }
        padTo4()
        let vcgtSize = UInt32(data.count) - vcgtOffset

        // Now patch tag table
        let tagSigs: [String] = ["desc", "wtpt", "rXYZ", "gXYZ", "bXYZ", "rTRC", "gTRC", "bTRC", "vcgt"]
        let offsets: [UInt32] = [descOffset, wtptOffset, rXYZOffset, gXYZOffset, bXYZOffset,
                                  rTRCOffset, gTRCOffset, bTRCOffset, vcgtOffset]
        let sizes: [UInt32] = [descSize, wtptSize, rXYZSize, gXYZSize, bXYZSize,
                                rTRCSize, gTRCSize, bTRCSize, vcgtSize]

        for i in 0..<Int(tagCount) {
            let entryOffset = tagTableStart + i * 12
            let sigBytes = Array(tagSigs[i].utf8)
            for j in 0..<4 { data[entryOffset + j] = sigBytes[j] }
            var off = offsets[i].bigEndian
            data.replaceSubrange(entryOffset+4..<entryOffset+8, with: Data(bytes: &off, count: 4))
            var sz = sizes[i].bigEndian
            data.replaceSubrange(entryOffset+8..<entryOffset+12, with: Data(bytes: &sz, count: 4))
        }

        // Patch profile size
        var profileSize = UInt32(data.count).bigEndian
        data.replaceSubrange(0..<4, with: Data(bytes: &profileSize, count: 4))

        return data
    }

    // MARK: - Export .cube

    @objc func exportCubeAction(_ sender: Any?) {
        curves[currentChannel.rawValue] = curveView.points

        let alert = NSAlert()
        alert.messageText = "Export .cube LUT"
        alert.informativeText = "Enter a name:"
        alert.addButton(withTitle: "Export")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = "DisplayTuner_LUT"
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let (rTable, gTable, bTable) = computeFinalLUT()

        // Build 33x33x33 3D LUT from 1D tables
        let size = 33
        var lines = [String]()
        lines.append("# Created by DisplayTuner v3")
        lines.append("TITLE \"\(name)\"")
        lines.append("LUT_3D_SIZE \(size)")
        lines.append("DOMAIN_MIN 0.0 0.0 0.0")
        lines.append("DOMAIN_MAX 1.0 1.0 1.0")
        lines.append("")

        for bi in 0..<size {
            for gi in 0..<size {
                for ri in 0..<size {
                    let rIn = Float(ri) / Float(size - 1)
                    let gIn = Float(gi) / Float(size - 1)
                    let bIn = Float(bi) / Float(size - 1)

                    let rIdx = min(255, max(0, Int(rIn * 255.0)))
                    let gIdx = min(255, max(0, Int(gIn * 255.0)))
                    let bIdx = min(255, max(0, Int(bIn * 255.0)))

                    let rOut = rTable[rIdx]
                    let gOut = gTable[gIdx]
                    let bOut = bTable[bIdx]

                    lines.append(String(format: "%.6f %.6f %.6f", rOut, gOut, bOut))
                }
            }
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Save .cube LUT"
        savePanel.nameFieldStringValue = "\(name).cube"

        savePanel.beginSheetModal(for: window) { response in
            if response == .OK, let url = savePanel.url {
                let content = lines.joined(separator: "\n")
                try? content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Test Patterns

    @objc func showTestPatterns(_ sender: Any?) {
        testPatternController.showWindow()
    }

    // MARK: - Warm-Up Timer

    func startWarmUpTimer() {
        warmUpSecondsRemaining = 1200
        warmUpTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.warmUpSecondsRemaining > 0 {
                self.warmUpSecondsRemaining -= 1
                let mins = self.warmUpSecondsRemaining / 60
                let secs = self.warmUpSecondsRemaining % 60
                self.warmUpLabel.stringValue = String(format: "Warm-up: %02d:%02d", mins, secs)
                if self.warmUpSecondsRemaining == 0 {
                    self.warmUpLabel.stringValue = "Warm-up: Ready"
                    self.warmUpLabel.textColor = NSColor(calibratedRed: 0.2, green: 0.9, blue: 0.2, alpha: 1.0)
                }
            }
        }
    }

    // MARK: - UI Helpers

    func makeLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let label = NSTextField(frame: NSRect(x: x, y: y, width: width, height: 18))
        label.stringValue = text
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.textColor = NSColor(calibratedWhite: 0.8, alpha: 1.0)
        label.font = NSFont.systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func makeTabButton(_ ch: CurveChannel, x: CGFloat, y: CGFloat, tag: Int) -> NSButton {
        let width: CGFloat = ch == .master ? 55 : 28
        let btn = NSButton(frame: NSRect(x: x, y: y, width: width, height: 22))
        btn.title = ch.title
        btn.bezelStyle = .smallSquare
        btn.isBordered = true
        btn.tag = tag
        btn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        if #available(macOS 10.14, *) {
            btn.contentTintColor = ch.color
        }
        return btn
    }

    func makeActionButton(_ title: String, x: CGFloat, y: CGFloat,
                           width: CGFloat, action: Selector) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: y, width: width, height: 26))
        btn.title = title
        btn.bezelStyle = .rounded
        btn.target = self
        btn.action = action
        btn.font = NSFont.systemFont(ofSize: 11)
        return btn
    }

    // MARK: - Window Delegate

    func windowWillClose(_ notification: Notification) {
        stopDithering()
        CGDisplayRestoreColorSyncSettings()
        warmUpTimer?.invalidate()
        NSApp.terminate(nil)
    }

    // MARK: - Keyboard Shortcuts (via responder chain)

    @objc func performUndo(_ sender: Any?) { undoAction(sender) }
    @objc func performRedo(_ sender: Any?) { redoAction(sender) }
}

// MARK: - Custom Window for Space Key

class TunerWindow: NSWindow {
    weak var tunerController: DisplayTunerController?

    override func keyDown(with event: NSEvent) {
        if event.characters == " " {
            tunerController?.togglePreview(nil)
        } else if event.modifierFlags.contains(.command) && event.characters == "z" {
            if event.modifierFlags.contains(.shift) {
                tunerController?.redoAction(nil)
            } else {
                tunerController?.undoAction(nil)
            }
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DisplayTunerController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        setupMenuBar()
        controller.buildUI()

        // Replace the standard NSWindow with our TunerWindow for key handling
        if let oldWindow = controller.window {
            let tunerWindow = TunerWindow(
                contentRect: oldWindow.frame,
                styleMask: oldWindow.styleMask,
                backing: .buffered,
                defer: false
            )
            tunerWindow.title = oldWindow.title
            tunerWindow.delegate = controller
            tunerWindow.isReleasedWhenClosed = false
            tunerWindow.backgroundColor = oldWindow.backgroundColor
            tunerWindow.minSize = oldWindow.minSize
            tunerWindow.tunerController = controller

            // Move all subviews
            if let oldContent = oldWindow.contentView, let newContent = tunerWindow.contentView {
                newContent.wantsLayer = true
                for subview in oldContent.subviews {
                    newContent.addSubview(subview)
                }
            }

            oldWindow.orderOut(nil)
            controller.window = tunerWindow
            tunerWindow.center()
            tunerWindow.makeKeyAndOrderFront(nil)
        }

        // Push initial undo state
        controller.pushUndoState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopDithering()
        CGDisplayRestoreColorSyncSettings()
    }

    func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About DisplayTuner v3",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit DisplayTuner v3",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(title: "Undo", action: #selector(DisplayTunerController.undoAction(_:)), keyEquivalent: "z")
        undoItem.target = controller
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo", action: #selector(DisplayTunerController.redoAction(_:)), keyEquivalent: "Z")
        redoItem.target = controller
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
