// DisplayTunerMenuBar.swift — Lightweight Menu Bar Daemon for Display LUT Management
// Compile: swiftc -O Sources/DisplayTunerMenuBar.swift -o DisplayTunerMenuBar -framework AppKit
// Single-file native AppKit app. No SwiftUI, no Xcode project.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Data Types (shared with DisplayTunerV3)

struct CurvePoint: Codable {
    var x: CGFloat
    var y: CGFloat
}

enum CurveChannel: Int, CaseIterable, Codable {
    case master = 0, red = 1, green = 2, blue = 3
    case cyan = 4, magenta = 5, yellow = 6, black = 7
}

struct TonalEQState: Codable {
    var bands: [Int: [Double]]
    init() {
        bands = [:]
        for ch in CurveChannel.allCases {
            bands[ch.rawValue] = [Double](repeating: 0.0, count: 12)
        }
    }
}

struct PresetData: Codable {
    var curves: [Int: [CurvePoint]]
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

// MARK: - Last Preset Tracking

struct LastPresetMap: Codable {
    var displays: [String: String]  // displayName -> settingName
    init() { displays = [:] }
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
    let M: [[Double]] = [
        [ 0.8951,  0.2664, -0.1614],
        [-0.7502,  1.7135,  0.0367],
        [ 0.0389, -0.0685,  1.0296]
    ]
    let (sx, sy) = kelvinToXY(sourceKelvin)
    let (sX, sY, sZ) = xyToXYZ(sx, sy)
    let (dx, dy) = kelvinToXY(destKelvin)
    let (dX, dY, dZ) = xyToXYZ(dx, dy)

    let sR = M[0][0] * sX + M[0][1] * sY + M[0][2] * sZ
    let sG = M[1][0] * sX + M[1][1] * sY + M[1][2] * sZ
    let sB = M[2][0] * sX + M[2][1] * sY + M[2][2] * sZ

    let dR = M[0][0] * dX + M[0][1] * dY + M[0][2] * dZ
    let dG = M[1][0] * dX + M[1][1] * dY + M[1][2] * dZ
    let dB = M[2][0] * dX + M[2][1] * dY + M[2][2] * dZ

    let rGain = (sR != 0) ? dR / sR : 1.0
    let gGain = (sG != 0) ? dG / sG : 1.0
    let bGain = (sB != 0) ? dB / sB : 1.0

    return (rGain, gGain, bGain)
}

// MARK: - Tonal EQ Constants & Helpers

let tonalBandCenters: [Double] = [0.02, 0.07, 0.12, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 0.97]
let tonalBandSigma: Double = 0.05

func gaussianWeight(_ x: CGFloat, center: CGFloat, sigma: CGFloat) -> CGFloat {
    let diff = x - center
    return exp(-(diff * diff) / (2 * sigma * sigma))
}

// MARK: - Signal Handlers

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

// MARK: - Preset Manager

class PresetManager {
    static let presetsDir: String = {
        let dir = NSString(string: "~/.config/displayctl/presets").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let lastPresetPath: String = {
        let dir = NSString(string: "~/.config/displayctl").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("last_preset.json")
    }()

    static func sanitizeDisplayName(_ name: String) -> String {
        return name.replacingOccurrences(of: " ", with: "_")
                   .replacingOccurrences(of: "(", with: "")
                   .replacingOccurrences(of: ")", with: "")
    }

    static func listPresets(forDisplay displayName: String) -> [(settingName: String, filename: String)] {
        let prefix = sanitizeDisplayName(displayName) + "-"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: presetsDir) else { return [] }
        var results: [(String, String)] = []
        for file in files.sorted() where file.hasSuffix(".json") && file.hasPrefix(prefix) {
            let name = String(file.dropFirst(prefix.count).dropLast(5)) // strip prefix and .json
            results.append((name, file))
        }
        return results
    }

    static func loadPreset(filename: String) -> PresetData? {
        let path = (presetsDir as NSString).appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(PresetData.self, from: data)
    }

    static func savePreset(_ preset: PresetData, displayName: String, settingName: String) {
        let filename = sanitizeDisplayName(displayName) + "-" + settingName + ".json"
        let path = (presetsDir as NSString).appendingPathComponent(filename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(preset) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func loadLastPresetMap() -> LastPresetMap {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: lastPresetPath)) else {
            return LastPresetMap()
        }
        return (try? JSONDecoder().decode(LastPresetMap.self, from: data)) ?? LastPresetMap()
    }

    static func saveLastPresetMap(_ map: LastPresetMap) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(map) {
            try? data.write(to: URL(fileURLWithPath: lastPresetPath))
        }
    }

    static func lastSettingName(forDisplay displayName: String) -> String? {
        let map = loadLastPresetMap()
        return map.displays[displayName]
    }

    static func setLastSettingName(_ settingName: String, forDisplay displayName: String) {
        var map = loadLastPresetMap()
        map.displays[displayName] = settingName
        saveLastPresetMap(map)
    }
}

// MARK: - Display Info

struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let isMain: Bool
}

func getOnlineDisplays() -> [DisplayInfo] {
    var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
    var displayCount: UInt32 = 0
    CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount)

    var results: [DisplayInfo] = []
    for i in 0..<Int(displayCount) {
        let did = onlineDisplays[i]
        let w = CGDisplayPixelsWide(did)
        let h = CGDisplayPixelsHigh(did)
        let isMain = CGDisplayIsMain(did) != 0
        var name = "\(w)x\(h)"
        if w == 2560 && h == 1600 { name = "Cinema HD \(w)x\(h)" }
        if isMain && !(w == 2560 && h == 1600) { name += " (Main)" }
        results.append(DisplayInfo(id: did, name: name, width: w, height: h, isMain: isMain))
    }
    return results
}

// MARK: - Slider Menu Item View

class SliderMenuItemView: NSView {
    let label: NSTextField
    let slider: NSSlider
    let valueLabel: NSTextField
    var onValueChanged: ((Double) -> Void)?

    init(title: String, minValue: Double, maxValue: Double, defaultValue: Double, width: CGFloat = 300) {
        label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .labelColor

        slider = NSSlider(value: defaultValue, minValue: minValue, maxValue: maxValue,
                          target: nil, action: nil)
        slider.isContinuous = true

        valueLabel = NSTextField(labelWithString: String(format: "%.2f", defaultValue))
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))

        label.frame = NSRect(x: 12, y: 4, width: 70, height: 18)
        slider.frame = NSRect(x: 82, y: 4, width: width - 140, height: 20)
        valueLabel.frame = NSRect(x: width - 56, y: 4, width: 48, height: 18)

        slider.target = self
        slider.action = #selector(sliderChanged(_:))

        addSubview(label)
        addSubview(slider)
        addSubview(valueLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func sliderChanged(_ sender: NSSlider) {
        valueLabel.stringValue = String(format: "%.2f", sender.doubleValue)
        onValueChanged?(sender.doubleValue)
    }
}

// MARK: - Menu Bar Controller

class MenuBarController: NSObject {
    var statusItem: NSStatusItem!
    var menu: NSMenu!

    // Current state per display
    var displays: [DisplayInfo] = []
    var selectedDisplayIndex: Int = 0

    // Slider values per display (keyed by display name)
    var brightnessValues: [String: Double] = [:]
    var contrastValues: [String: Double] = [:]
    var detailValues: [String: Double] = [:]

    // Current preset per display
    var currentPresetName: [String: String] = [:]

    // Loaded preset data per display
    var loadedPresets: [String: PresetData] = [:]

    // Menu items
    var displaySubmenuItem: NSMenuItem!
    var brightnessView: SliderMenuItemView!
    var contrastView: SliderMenuItemView!
    var detailView: SliderMenuItemView!
    var presetSubmenuItem: NSMenuItem!

    // Debounce timer for LUT application
    var lutTimer: Timer?

    var selectedDisplay: DisplayInfo? {
        guard selectedDisplayIndex >= 0 && selectedDisplayIndex < displays.count else { return nil }
        return displays[selectedDisplayIndex]
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "display", accessibilityDescription: "DisplayTuner") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "\u{1F5A5}"
            }
        }

        displays = getOnlineDisplays()
        if displays.isEmpty { return }

        // Initialize default slider values for all displays
        for d in displays {
            brightnessValues[d.name] = 1.0
            contrastValues[d.name] = 1.0
            detailValues[d.name] = 0.0
        }

        // Auto-load last presets
        autoLoadLastPresets()

        buildMenu()
        statusItem.menu = menu
    }

    func autoLoadLastPresets() {
        for display in displays {
            if let settingName = PresetManager.lastSettingName(forDisplay: display.name) {
                let prefix = PresetManager.sanitizeDisplayName(display.name)
                let filename = "\(prefix)-\(settingName).json"
                if let preset = PresetManager.loadPreset(filename: filename) {
                    loadedPresets[display.name] = preset
                    currentPresetName[display.name] = settingName
                    // Apply preset LUT to this display
                    applyLUTToDisplay(display)
                }
            }
        }
    }

    // MARK: - Menu Construction

    func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Header
        let headerItem = NSMenuItem(title: "DisplayTuner", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        headerItem.attributedTitle = NSAttributedString(
            string: "DisplayTuner",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Display selector
        displaySubmenuItem = NSMenuItem(title: "Display: \(selectedDisplay?.name ?? "None")",
                                        action: nil, keyEquivalent: "")
        let displaySubmenu = NSMenu()
        for (i, d) in displays.enumerated() {
            let item = NSMenuItem(title: d.name, action: #selector(selectDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            if i == selectedDisplayIndex { item.state = .on }
            displaySubmenu.addItem(item)
        }
        displaySubmenuItem.submenu = displaySubmenu
        menu.addItem(displaySubmenuItem)
        menu.addItem(NSMenuItem.separator())

        // Brightness slider
        brightnessView = SliderMenuItemView(title: "Brightness:", minValue: 0.5, maxValue: 1.5, defaultValue: 1.0)
        brightnessView.onValueChanged = { [weak self] val in
            guard let self = self, let d = self.selectedDisplay else { return }
            self.brightnessValues[d.name] = val
            self.scheduleLUTUpdate()
        }
        let brightnessItem = NSMenuItem()
        brightnessItem.view = brightnessView
        menu.addItem(brightnessItem)

        // Contrast slider
        contrastView = SliderMenuItemView(title: "Contrast:", minValue: 0.5, maxValue: 2.0, defaultValue: 1.0)
        contrastView.onValueChanged = { [weak self] val in
            guard let self = self, let d = self.selectedDisplay else { return }
            self.contrastValues[d.name] = val
            self.scheduleLUTUpdate()
        }
        let contrastItem = NSMenuItem()
        contrastItem.view = contrastView
        menu.addItem(contrastItem)

        // Detail slider
        detailView = SliderMenuItemView(title: "Detail:", minValue: 0.0, maxValue: 1.0, defaultValue: 0.0)
        detailView.onValueChanged = { [weak self] val in
            guard let self = self, let d = self.selectedDisplay else { return }
            self.detailValues[d.name] = val
            self.scheduleLUTUpdate()
        }
        let detailItem = NSMenuItem()
        detailItem.view = detailView
        menu.addItem(detailItem)

        menu.addItem(NSMenuItem.separator())

        // Preset dropdown
        presetSubmenuItem = NSMenuItem(title: "Preset: \(currentPresetName[selectedDisplay?.name ?? ""] ?? "(none)")",
                                       action: nil, keyEquivalent: "")
        rebuildPresetSubmenu()
        menu.addItem(presetSubmenuItem)

        menu.addItem(NSMenuItem.separator())

        // Open DisplayTuner
        let openItem = NSMenuItem(title: "Open DisplayTuner", action: #selector(openDisplayTuner(_:)), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        // Reset Display
        let resetItem = NSMenuItem(title: "Reset Display", action: #selector(resetDisplay(_:)), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func rebuildPresetSubmenu() {
        guard let d = selectedDisplay else { return }
        let presetSubmenu = NSMenu()

        let presets = PresetManager.listPresets(forDisplay: d.name)
        let current = currentPresetName[d.name]

        if presets.isEmpty {
            let noneItem = NSMenuItem(title: "(no presets)", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            presetSubmenu.addItem(noneItem)
        } else {
            for (settingName, _) in presets {
                let item = NSMenuItem(title: settingName, action: #selector(selectPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = settingName
                if settingName == current { item.state = .on }
                presetSubmenu.addItem(item)
            }
        }

        presetSubmenu.addItem(NSMenuItem.separator())

        let saveItem = NSMenuItem(title: "Save Current Settings...", action: #selector(saveCurrentSettings(_:)),
                                  keyEquivalent: "")
        saveItem.target = self
        presetSubmenu.addItem(saveItem)

        presetSubmenuItem.submenu = presetSubmenu
        presetSubmenuItem.title = "Preset: \(current ?? "(none)")"
    }

    // MARK: - Slider → Display Sync

    func updateSlidersForSelectedDisplay() {
        guard let d = selectedDisplay else { return }
        let b = brightnessValues[d.name] ?? 1.0
        let c = contrastValues[d.name] ?? 1.0
        let dt = detailValues[d.name] ?? 0.0

        brightnessView.slider.doubleValue = b
        brightnessView.valueLabel.stringValue = String(format: "%.2f", b)
        contrastView.slider.doubleValue = c
        contrastView.valueLabel.stringValue = String(format: "%.2f", c)
        detailView.slider.doubleValue = dt
        detailView.valueLabel.stringValue = String(format: "%.2f", dt)
    }

    // MARK: - Actions

    @objc func selectDisplay(_ sender: NSMenuItem) {
        selectedDisplayIndex = sender.tag
        // Update check marks
        if let submenu = displaySubmenuItem.submenu {
            for item in submenu.items {
                item.state = item.tag == sender.tag ? .on : .off
            }
        }
        displaySubmenuItem.title = "Display: \(selectedDisplay?.name ?? "None")"
        updateSlidersForSelectedDisplay()
        rebuildPresetSubmenu()
    }

    @objc func selectPreset(_ sender: NSMenuItem) {
        guard let d = selectedDisplay, let settingName = sender.representedObject as? String else { return }
        let prefix = PresetManager.sanitizeDisplayName(d.name)
        let filename = "\(prefix)-\(settingName).json"
        guard let preset = PresetManager.loadPreset(filename: filename) else { return }

        loadedPresets[d.name] = preset
        currentPresetName[d.name] = settingName
        PresetManager.setLastSettingName(settingName, forDisplay: d.name)
        rebuildPresetSubmenu()
        applyLUTToDisplay(d)
    }

    @objc func saveCurrentSettings(_ sender: Any?) {
        guard let d = selectedDisplay else { return }

        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Enter a name for this preset (for \(d.name)):"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = "default"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        guard !name.isEmpty else { return }

        // Build preset from current state
        let preset = loadedPresets[d.name] ?? PresetData()
        // The preset's slider adjustments are baked into the LUT at apply time;
        // save the base curves/tonalEQ as-is. The user can re-adjust sliders.
        PresetManager.savePreset(preset, displayName: d.name, settingName: name)
        currentPresetName[d.name] = name
        PresetManager.setLastSettingName(name, forDisplay: d.name)
        rebuildPresetSubmenu()
    }

    @objc func openDisplayTuner(_ sender: Any?) {
        // Try to find DisplayTuner binary next to ourselves
        let myPath = CommandLine.arguments[0]
        let myDir = (myPath as NSString).deletingLastPathComponent
        let tunerPath = (myDir as NSString).appendingPathComponent("DisplayTuner")
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: tunerPath) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tunerPath)
            try? proc.run()
        } else {
            // Try same directory as the source
            let altPath = NSString(string: "~/github/DisplayTuner/DisplayTuner").expandingTildeInPath
            if fm.isExecutableFile(atPath: altPath) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: altPath)
                try? proc.run()
            }
        }
    }

    @objc func resetDisplay(_ sender: Any?) {
        guard let d = selectedDisplay else { return }
        CGDisplayRestoreColorSyncSettings()
        loadedPresets[d.name] = nil
        currentPresetName[d.name] = nil
        brightnessValues[d.name] = 1.0
        contrastValues[d.name] = 1.0
        detailValues[d.name] = 0.0
        updateSlidersForSelectedDisplay()
        rebuildPresetSubmenu()
    }

    @objc func quitApp(_ sender: Any?) {
        CGDisplayRestoreColorSyncSettings()
        NSApp.terminate(nil)
    }

    // MARK: - LUT Pipeline

    func scheduleLUTUpdate() {
        lutTimer?.invalidate()
        lutTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
            guard let self = self, let d = self.selectedDisplay else { return }
            self.applyLUTToDisplay(d)
        }
    }

    func applyLUTToDisplay(_ display: DisplayInfo) {
        let preset = loadedPresets[display.name] ?? PresetData()
        let brightness = brightnessValues[display.name] ?? 1.0
        let contrast = contrastValues[display.name] ?? 1.0
        let detail = detailValues[display.name] ?? 0.0

        let (rTable, gTable, bTable) = computeLUT(preset: preset,
                                                    brightness: brightness,
                                                    contrast: contrast,
                                                    detail: detail)

        // SAFETY: reject if any channel peak < 0.1
        guard let rMax = rTable.max(), let gMax = gTable.max(), let bMax = bTable.max(),
              rMax >= 0.1, gMax >= 0.1, bMax >= 0.1 else {
            return
        }

        // SAFETY: clamp minimum to 0.03 for indices > 0
        var r = rTable.enumerated().map { $0.offset == 0 ? $0.element : max(0.03, $0.element) }
        var g = gTable.enumerated().map { $0.offset == 0 ? $0.element : max(0.03, $0.element) }
        var b = bTable.enumerated().map { $0.offset == 0 ? $0.element : max(0.03, $0.element) }

        CGSetDisplayTransferByTable(display.id, 256, &r, &g, &b)
    }

    func computeLUT(preset: PresetData, brightness: Double, contrast: Double, detail: Double) -> ([Float], [Float], [Float]) {
        // Step 1: Interpolate curves from preset
        let masterLUT = monotonicCubicInterpolation(
            points: preset.curves[CurveChannel.master.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let redLUT = monotonicCubicInterpolation(
            points: preset.curves[CurveChannel.red.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let greenLUT = monotonicCubicInterpolation(
            points: preset.curves[CurveChannel.green.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let blueLUT = monotonicCubicInterpolation(
            points: preset.curves[CurveChannel.blue.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)

        let cyanLUT = monotonicCubicInterpolation(
            points: preset.curves[CurveChannel.cyan.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let magentaLUT = monotonicCubicInterpolation(
            points: preset.curves[CurveChannel.magenta.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let yellowLUT = monotonicCubicInterpolation(
            points: preset.curves[CurveChannel.yellow.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)
        let blackLUT = monotonicCubicInterpolation(
            points: preset.curves[CurveChannel.black.rawValue] ?? [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)],
            steps: 256)

        // Bradford white point gains
        let (wpR, wpG, wpB) = bradfordGains(sourceKelvin: 6504, destKelvin: preset.whitePointKelvin)

        let targetGamma = preset.targetGamma ?? 2.2

        var rTable = [Float](repeating: 0, count: 256)
        var gTable = [Float](repeating: 0, count: 256)
        var bTable = [Float](repeating: 0, count: 256)

        // Pre-compute base LUT (curves + tonal EQ + white point + gamma)
        var baseLUT_R = [CGFloat](repeating: 0, count: 256)
        var baseLUT_G = [CGFloat](repeating: 0, count: 256)
        var baseLUT_B = [CGFloat](repeating: 0, count: 256)

        for i in 0..<256 {
            let t = CGFloat(i) / 255.0

            // Master curve
            let afterMaster = masterLUT[i]

            // Per-channel RGB
            let rIdx = min(255, max(0, Int(afterMaster * 255.0)))
            var r = redLUT[rIdx]
            var g = greenLUT[rIdx]
            var b = blueLUT[rIdx]

            // CMYK deltas
            let identity = t
            let cDelta = cyanLUT[i] - identity
            let mDelta = magentaLUT[i] - identity
            let yDelta = yellowLUT[i] - identity
            let kDelta = blackLUT[i] - identity
            r -= (cDelta + kDelta)
            g -= (mDelta + kDelta)
            b -= (yDelta + kDelta)

            // Tonal EQ
            r = applyTonalEQ(r, originalT: t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.master.rawValue)
            r = applyTonalEQ(r, originalT: t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.red.rawValue)
            g = applyTonalEQ(g, originalT: t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.master.rawValue)
            g = applyTonalEQ(g, originalT: t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.green.rawValue)
            b = applyTonalEQ(b, originalT: t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.master.rawValue)
            b = applyTonalEQ(b, originalT: t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.blue.rawValue)

            // CMYK tonal EQ
            let cEQ = computeTonalEQDelta(t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.cyan.rawValue)
            let mEQ = computeTonalEQDelta(t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.magenta.rawValue)
            let yEQ = computeTonalEQDelta(t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.yellow.rawValue)
            let kEQ = computeTonalEQDelta(t, bands: preset.tonalEQ.bands, channelRaw: CurveChannel.black.rawValue)
            r -= (cEQ + kEQ)
            g -= (mEQ + kEQ)
            b -= (yEQ + kEQ)

            // White point
            r *= CGFloat(wpR)
            g *= CGFloat(wpG)
            b *= CGFloat(wpB)

            // Target gamma
            if abs(targetGamma - 2.2) > 0.001 {
                let gammaExp = CGFloat(targetGamma / 2.2)
                if r > 0 { r = pow(r, gammaExp) }
                if g > 0 { g = pow(g, gammaExp) }
                if b > 0 { b = pow(b, gammaExp) }
            }

            baseLUT_R[i] = r
            baseLUT_G[i] = g
            baseLUT_B[i] = b
        }

        // Step 2: Apply brightness gamma
        // output = input ^ (1.0/brightness)
        for i in 0..<256 {
            var r = baseLUT_R[i]
            var g = baseLUT_G[i]
            var b = baseLUT_B[i]

            if abs(brightness - 1.0) > 0.001 {
                let gammaExp = CGFloat(1.0 / brightness)
                if r > 0 { r = pow(max(0, r), gammaExp) }
                if g > 0 { g = pow(max(0, g), gammaExp) }
                if b > 0 { b = pow(max(0, b), gammaExp) }
            }

            baseLUT_R[i] = r
            baseLUT_G[i] = g
            baseLUT_B[i] = b
        }

        // Step 3: Apply contrast S-curve
        // output = 0.5 + (input - 0.5) * contrast, clamped
        if abs(contrast - 1.0) > 0.001 {
            for i in 0..<256 {
                baseLUT_R[i] = max(0, min(1, 0.5 + (baseLUT_R[i] - 0.5) * CGFloat(contrast)))
                baseLUT_G[i] = max(0, min(1, 0.5 + (baseLUT_G[i] - 0.5) * CGFloat(contrast)))
                baseLUT_B[i] = max(0, min(1, 0.5 + (baseLUT_B[i] - 0.5) * CGFloat(contrast)))
            }
        }

        // Step 4: Apply detail (pseudo-sharpness) — unsharp-mask-like LUT enhancement
        // output = input + detail * (input - blurred_input) using 5-sample box blur of LUT
        if detail > 0.001 {
            let blurR = boxBlurLUT(baseLUT_R, radius: 2)
            let blurG = boxBlurLUT(baseLUT_G, radius: 2)
            let blurB = boxBlurLUT(baseLUT_B, radius: 2)

            for i in 0..<256 {
                baseLUT_R[i] = baseLUT_R[i] + CGFloat(detail) * (baseLUT_R[i] - blurR[i])
                baseLUT_G[i] = baseLUT_G[i] + CGFloat(detail) * (baseLUT_G[i] - blurG[i])
                baseLUT_B[i] = baseLUT_B[i] + CGFloat(detail) * (baseLUT_B[i] - blurB[i])
            }
        }

        // Step 5: Safety clamp
        for i in 0..<256 {
            var r = max(0, min(1, baseLUT_R[i]))
            var g = max(0, min(1, baseLUT_G[i]))
            var b = max(0, min(1, baseLUT_B[i]))

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

    func boxBlurLUT(_ lut: [CGFloat], radius: Int) -> [CGFloat] {
        let count = lut.count
        var result = [CGFloat](repeating: 0, count: count)

        for i in 0..<count {
            var sum: CGFloat = 0
            var samples = 0
            for j in (i - radius)...(i + radius) {
                let idx = max(0, min(count - 1, j))
                sum += lut[idx]
                samples += 1
            }
            result[i] = sum / CGFloat(samples)
        }
        return result
    }

    func applyTonalEQ(_ value: CGFloat, originalT: CGFloat, bands: [Int: [Double]], channelRaw: Int) -> CGFloat {
        guard let bandValues = bands[channelRaw] else { return value }
        var v = value
        for band in 0..<min(12, bandValues.count) {
            let center = CGFloat(tonalBandCenters[band])
            let sigma = CGFloat(tonalBandSigma)
            let weight = gaussianWeight(originalT, center: center, sigma: sigma)
            v += CGFloat(bandValues[band]) * weight * 0.5
        }
        return v
    }

    func computeTonalEQDelta(_ t: CGFloat, bands: [Int: [Double]], channelRaw: Int) -> CGFloat {
        guard let bandValues = bands[channelRaw] else { return 0 }
        var delta: CGFloat = 0
        for band in 0..<min(12, bandValues.count) {
            let center = CGFloat(tonalBandCenters[band])
            let sigma = CGFloat(tonalBandSigma)
            let weight = gaussianWeight(t, center: center, sigma: sigma)
            delta += CGFloat(bandValues[band]) * weight * 0.5
        }
        return delta
    }
}

// MARK: - NSMenuDelegate

extension MenuBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Refresh display list in case displays changed
        let newDisplays = getOnlineDisplays()
        if newDisplays.count != displays.count {
            displays = newDisplays
            selectedDisplayIndex = min(selectedDisplayIndex, displays.count - 1)
            buildMenu()
            statusItem.menu = self.menu
        }
        updateSlidersForSelectedDisplay()
        rebuildPresetSubmenu()
    }
}

// MARK: - App Delegate

class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    let controller = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        controller.setup()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayRestoreColorSyncSettings()
    }
}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = MenuBarAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // LSUIElement: no dock icon
app.run()
