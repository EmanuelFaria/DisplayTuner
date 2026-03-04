# DisplayTuner -- Product Requirements Document

## 1. Overview

**DisplayTuner** is a macOS display calibration application that modifies the GPU's gamma lookup table (LUT) in real time using the CoreGraphics `CGSetDisplayTransferByTable` API. It provides professional-grade curve editing, tonal equalization, white point targeting, and cross-display color matching in a single-file native AppKit application with no external dependencies.

The application targets users who need to correct the color output of aging or uncalibrated external displays -- particularly older Apple Cinema HD displays and similar monitors where macOS built-in display settings, MonitorControl, and Night Shift are insufficient for serious color work.

## 2. Background

The Apple Cinema HD 30" (model A1083) uses a CCFL-backlit S-IPS panel that degrades over time. After years of use, these displays develop:

- **Yellow/warm color cast** -- CCFL aging shifts the white point toward lower color temperatures
- **Shadow crushing** -- the lowest luminance steps become indistinguishable
- **Highlight clipping** -- the top luminance steps merge into uniform white
- **Non-uniform gamma** -- the transfer function drifts from its factory calibration

macOS provides no built-in tool for arbitrary gamma table manipulation. Third-party tools like DisplayCAL require colorimeters (hardware investment), and MonitorControl only adjusts brightness/contrast via DDC/CI (not supported by Cinema HD over DVI).

DisplayTuner was created to solve this specific problem using only the software gamma ramp -- no hardware required -- while implementing enough safety guards to prevent accidentally blacking out the display.

## 3. Goals

1. Provide real-time, interactive display color correction via GPU gamma table manipulation
2. Offer professional-grade curve editing comparable to Photoshop Curves (8 channels: Master, RGB, CMYK)
3. Include targeted tonal adjustments (12-band EQ) for precision shadow/highlight recovery
4. Support perceptually accurate white point targeting via Bradford chromatic adaptation
5. Export corrections as ICC profiles with vcgt tags for persistent, app-independent calibration
6. Export as `.cube` 3D LUT files for integration with video editing software
7. Provide visual verification tools (ColorChecker with CIEDE2000, gamma verification patterns)
8. Match color output between multiple connected displays
9. Deliver a lightweight menu bar daemon for day-to-day quick adjustments
10. Prevent display blackout through multiple safety layers

## 4. Non-Goals

1. **Per-pixel sharpening via gamma** -- The gamma LUT is a 256-entry transfer function, not a spatial filter. Per-pixel operations (unsharp mask, edge enhancement) require a different mechanism (Core Image overlay or Metal shader) and are outside the scope of LUT-based calibration.

2. **3D LUT at the display level** -- macOS `CGSetDisplayTransferByTable` accepts three 1D LUTs (R, G, B), not a 3D LUT. True 3D LUT application would require intercepting the display pipeline at a lower level, which macOS does not expose. The `.cube` export is for use in video editing applications, not for display-level application.

3. **BetterDisplay virtual screen integration** -- BetterDisplay creates virtual displays for resolution scaling. While DisplayTuner detects and can list these virtual displays, calibrating them is unreliable because BetterDisplay's mirroring pipeline may override the gamma table. The menu bar app filters out virtual displays; the main app includes them only for specialized workflows.

4. **Hardware DDC/CI control** -- DisplayTuner does not send DDC/CI commands to adjust the monitor's OSD settings (hardware brightness, contrast, input selection). This is the domain of tools like MonitorControl.

5. **Colorimeter integration** -- There is no support for reading measurements from i1Display, ColorMunki, or other colorimeter hardware. Calibration is visual and eyedropper-based.

6. **System-wide color management** -- DisplayTuner modifies the gamma ramp for a single display. It does not implement a complete color management system (no ICC rendering intents, no gamut mapping between displays).

## 5. User Stories

### US-1: Basic Display Calibration
> As a photographer with an aging Cinema HD display, I want to adjust the gamma curves to remove the yellow color cast and recover shadow detail, so that my photo edits look correct.

### US-2: A/B Comparison
> As a colorist, I want to instantly toggle between my calibration and the raw display output by pressing Space, so that I can verify my corrections are an improvement.

### US-3: Persistent Calibration
> As a user who has calibrated my display, I want to export an ICC profile with a vcgt tag, so that macOS automatically applies my calibration on every boot without running the app.

### US-4: Cross-Display Matching
> As a user with a Samsung 4K as my primary monitor and a Cinema HD as my secondary, I want to match the Cinema HD's color output to the Samsung, so that content looks consistent when dragged between displays.

### US-5: Quick Daily Adjustments
> As a user who sometimes works in dim evening lighting and sometimes in bright daylight, I want a menu bar app with brightness and contrast sliders, so that I can quickly adjust my display correction without opening the full editor.

### US-6: Video Color Grading Reference
> As a video editor, I want to export my display calibration as a `.cube` 3D LUT file, so that I can apply the inverse correction in DaVinci Resolve to preview how my color grade will look on a calibrated display.

## 6. System Architecture

### 6.1 Two-App Design

```
+--------------------------+    +----------------------------+
|    DisplayTuner          |    |   DisplayTunerMenuBar      |
|    (Full Editor)         |    |   (Menu Bar Daemon)        |
|                          |    |                            |
|  - 520x520 curve grid    |    |  - Status bar icon         |
|  - 12-band tonal EQ      |    |  - Brightness/Contrast     |
|  - White point controls   |    |    sliders                 |
|  - Cross-display match   |    |  - Preset dropdown         |
|  - Test patterns          |    |  - Display selector        |
|  - ICC/cube export        |    |  - Launch/hide main app    |
|  - Eyedropper tools       |    |                            |
|                          |    |  Activation: .accessory    |
|  Activation: .regular    |    |  (no Dock icon)            |
|  (Dock icon + menu bar)  |    |                            |
+-----------+--------------+    +-------------+--------------+
            |                                 |
            v                                 v
    +-------+------+                  +-------+------+
    | CGSetDisplay  |                  | CGSetDisplay  |
    | TransferBy    |                  | TransferBy    |
    | Table         |                  | Table         |
    +-------+------+                  +-------+------+
            |                                 |
            v                                 v
    +-------+------+                  +-------+------+
    |   GPU Gamma   |                  |   GPU Gamma   |
    |   LUT (256)   |                  |   LUT (256)   |
    +--------------+                  +--------------+
```

### 6.2 Single-File Swift Compilation

Each app is a single `.swift` file compiled directly with `swiftc`. No Xcode project, no Package.swift, no external dependencies. This design choice ensures:

- Zero build configuration complexity
- No dependency management
- Trivial CI/CD (one `swiftc` command)
- Easy auditing (the entire app is one file)

```bash
# Main app
swiftc -O Sources/DisplayTunerV3.swift -o DisplayTuner \
    -framework AppKit -framework CoreImage -framework QuartzCore

# Menu bar daemon
swiftc -O Sources/DisplayTunerMenuBar.swift -o DisplayTunerMenuBar \
    -framework AppKit
```

### 6.3 Core Mechanism: CGSetDisplayTransferByTable

The entire calibration system rests on a single CoreGraphics API:

```swift
CGSetDisplayTransferByTable(
    displayID: CGDirectDisplayID,
    tableSize: UInt32,           // always 256
    redTable: UnsafePointer<Float>,
    greenTable: UnsafePointer<Float>,
    blueTable: UnsafePointer<Float>
)
```

This replaces the GPU's gamma lookup table for a specific display. Input values 0-255 are mapped through the table to produce output values 0.0-1.0. The change takes effect immediately and persists until:
- Another call to `CGSetDisplayTransferByTable`
- A call to `CGDisplayRestoreColorSyncSettings()`
- The display disconnects or the system sleeps

### 6.4 ICC Profile Export

Exported ICC profiles are ICC v2.4 (`0x02400000`) with:
- **Profile class**: `mntr` (Monitor)
- **Color space**: `RGB`
- **PCS**: `XYZ`
- **Tags**: `desc`, `wtpt`, `rXYZ`, `gXYZ`, `bXYZ`, `rTRC`, `gTRC`, `bTRC`, `vcgt`

The `vcgt` (Video Card Gamma Table) tag is a private tag recognized by macOS ColorSync. When the profile is assigned to a display, macOS reads the vcgt and automatically loads it into the GPU gamma table. This makes the calibration persistent without running DisplayTuner.

### 6.5 Preset System

```
~/.config/displayctl/
    presets/
        2560x1600-cinema-default.json
        2560x1600-warm-evening.json
        3840x2160-samsung-calibrated.json
    last_preset.json
```

- **Preset files** are JSON-encoded `PresetData` structs, prefixed with the display's resolution
- **last_preset.json** maps display names to their last-used preset setting name
- Both apps share the same preset directory and last-preset tracking
- Display names are sanitized: spaces to underscores, parentheses removed
- Setting names are sanitized: alphanumeric, underscore, and hyphen only (path traversal prevention)

## 7. Feature Specifications

### 7.1 Curves Engine

**Control points**: Each of the 8 channels stores an array of `CurvePoint(x, y)` where both x and y are `CGFloat` in the range [0, 1]. Default: two points at (0,0) and (1,1) representing the identity curve.

**Interpolation**: Monotone cubic Hermite (Fritsch-Carlson method) generating 256 output values. The algorithm:
1. Sort points by x
2. Compute slopes between adjacent points
3. Set initial tangents as average of adjacent slopes
4. Zero tangents where slopes change sign (monotonicity enforcement)
5. Apply the Fritsch-Carlson 3-tau limiter to prevent overshoot
6. Evaluate the Hermite basis functions (h00, h10, h01, h11) at 256 uniform steps
7. Clamp output to [0, 1]

**Grid**: 520x520 pixels with quarter-mark gridlines (horizontal at 25%, 50%, 75%) and vertical gridlines at tonal EQ band positions. Identity diagonal shown as dashed line. Dark background (white 0.10).

**Interaction**:
- Click empty space to add a point
- Drag existing points to move them
- Right-click a point to delete it (minimum 2 points enforced)
- Hit radius: 10 pixels

**Channels**: Master (white), Red, Green, Blue, Cyan, Magenta, Yellow, Black. Each channel has its own color for the curve line.

### 7.2 Tonal EQ

**Architecture**: 12 bands per channel, 8 channels = 96 independent faders.

**Band centers** (fraction of luminance range):

| Band | Label | Center |
|------|-------|--------|
| 0 | Blk | 0.02 |
| 1 | DSh | 0.07 |
| 2 | Shd | 0.12 |
| 3 | LSh | 0.20 |
| 4 | LMd | 0.30 |
| 5 | MLo | 0.40 |
| 6 | Mid | 0.50 |
| 7 | MHi | 0.60 |
| 8 | HMd | 0.70 |
| 9 | Hlt | 0.80 |
| 10 | HLt | 0.90 |
| 11 | PkW | 0.97 |

**Influence**: Each band applies a Gaussian weight centered at its position with sigma = 0.05:

```
weight(t) = exp(-(t - center)^2 / (2 * sigma^2))
adjustment = band_value * weight * 0.5
```

The 0.5 scaling factor limits the maximum adjustment to half the fader range.

**Application**: Master tonal EQ is applied to all three RGB channels. Per-channel tonal EQ (R/G/B) is applied additively. CMYK tonal EQ is applied as subtractive delta (same as CMYK curves).

### 7.3 White Point Targeting

**Source**: D65 (6504K) assumed as the display's native white point.

**Method**: Bradford chromatic adaptation transform (diagonal adaptation in cone response domain).

**Bradford matrix**:
```
M = [[ 0.8951,  0.2664, -0.1614],
     [-0.7502,  1.7135,  0.0367],
     [ 0.0389, -0.0685,  1.0296]]
```

**Process**:
1. Convert source and destination Kelvin to CIE xy chromaticity via Planckian locus approximation
2. Convert xy to XYZ (Y=1 normalization)
3. Transform both XYZ to cone response domain via Bradford matrix M
4. Compute per-channel gains: `gain = dest_cone / source_cone`
5. Apply gains as multipliers to R, G, B channels

**Presets**: D50 (5003K), D55 (5503K), D65 (6504K), D75 (7504K), plus continuous slider 3200K-9300K.

**Kelvin-to-xy conversion**: Uses the CIE approximation formulas for the Planckian locus (Hernandez-Andres et al. 1999) with piecewise polynomials for different temperature ranges.

### 7.4 Preview ON/OFF

- Default state: OFF (no gamma modification on startup)
- Toggle: Space bar or Preview button
- When turning OFF: applies identity LUT to target display only
- When turning ON: re-applies the current LUT if user has interacted
- Auto-enables on first interaction (curve drag, slider move, preset load)
- LIVE indicator: green "LIVE" when active, gray "OFF" when inactive

### 7.5 Undo/Redo

- **Stack depth**: 50 states maximum (FIFO overflow -- oldest states discarded)
- **State captured**: `UndoState` struct containing:
  - All 8 curve channel point arrays
  - All 96 tonal EQ band values
  - White point Kelvin
  - Target gamma
- **Triggers**: Every curve change, tonal EQ slider change, white point change, gamma change, eyedropper pick, color match
- **Redo stack**: Cleared on any new user action (standard undo behavior)
- Quick adjust sliders (brightness, contrast, hue, saturation) are NOT captured in undo state -- they are transient adjustments

### 7.6 Preset Management

**Save As New**: Prompts for a setting name, saves current curves/tonalEQ/whitePoint/gamma/previewState as a display-prefixed JSON file.

**Load**: Select from the preset dropdown. Display-specific presets appear first, separated from other presets. Loading a preset forces Preview ON and pushes an undo state.

**Rename**: Renames the file on disk and updates last_preset.json.

**Delete**: Confirmation dialog, removes the file, clears last_preset tracking.

**Browse**: Opens an NSOpenPanel to load any JSON preset file, even from outside the presets directory.

**Auto-load**: On display switch, the last-used preset for that display is automatically loaded if available.

### 7.7 Cross-Display Calibration

#### Match Color (Manual Eyedropper)

1. User clicks "Match Color"
2. `NSColorSampler` opens for Step 1: pick a color on the TARGET display
3. After picking, a second `NSColorSampler` opens for Step 2: pick the same color on the REFERENCE display
4. For each RGB channel, a curve correction point is inserted: `x = source_value, y = target_value`
5. Existing points within 0.02 of the source x-position are removed first (deduplication)
6. Process can be repeated for multiple color samples to build a comprehensive correction

#### Quick Match (Automated)

1. Reads the reference display's ICC profile via `CGDisplayCopyColorSpace`
2. Extracts the rTRC tag from the ICC profile data
3. Parses the tag to determine gamma:
   - `curv` with 0 entries: gamma = 1.0 (identity)
   - `curv` with 1 entry: u8Fixed8Number gamma value
   - `curv` with multiple entries: estimates gamma from midpoint value using `gamma = log(output) / log(input)`
   - `para` type 0: reads s15Fixed16 gamma directly
4. Generates 21-point correction curves for R, G, B: `y = pow(x, refGamma / 2.2)`

### 7.8 Test Patterns

- Created as `NSWindow` instances, one per connected display
- Support full-screen mode (per window)
- Pattern type synchronized across all windows (changing pattern on one changes all)
- Include Match Color and Quick Match buttons in the toolbar (accessible even in full-screen)
- Status label for color matching feedback

**ColorChecker implementation**: Uses X-Rite published L*a*b* reference values (D50 illuminant) for all 24 patches. Renders sRGB approximations of each patch with CIEDE2000 Delta-E overlays.

### 7.9 ICC Export

**In-app export** (built into the Swift app): Builds a minimal ICC v2.4 profile binary in memory using:

| Tag | Content |
|-----|---------|
| `desc` | User-provided profile name |
| `wtpt` | D50 PCS white point (0.9505, 1.0, 1.0890) |
| `rXYZ` | sRGB red primary, D50 adapted (0.4361, 0.2225, 0.0139) |
| `gXYZ` | sRGB green primary, D50 adapted (0.3851, 0.7169, 0.0971) |
| `bXYZ` | sRGB blue primary, D50 adapted (0.1431, 0.0606, 0.7142) |
| `rTRC` | 256-entry curv tag (red channel LUT) |
| `gTRC` | 256-entry curv tag (green channel LUT) |
| `bTRC` | 256-entry curv tag (blue channel LUT) |
| `vcgt` | 256-entry table-type vcgt (3 channels, u16 values) |

**Standalone Python script** (`Scripts/lut_to_icc.py`): Reads a JSON LUT export and builds the same ICC structure. Also supports `.cube` export.

**Validation**:
- LUT peak values must be >= 0.1 for all channels (prevents export of dangerously dark profiles)
- Profile size assertion (`len(profile) == declared_size`)
- `acsp` magic number verification
- Mid-gray neutral deviation warning (> 50 units from 128)

### 7.10 .cube 3D LUT Export

- Format: standard `.cube` (DaVinci Resolve / Final Cut Pro compatible)
- Size: 33x33x33 grid points
- Generated from the three 1D LUTs by independent per-channel lookup
- Includes TITLE, LUT_3D_SIZE, DOMAIN_MIN, DOMAIN_MAX headers
- Saved via NSSavePanel to user-chosen location

### 7.11 Menu Bar Daemon

- **Activation policy**: `.accessory` (no Dock icon)
- **Icon**: SF Symbol `display` (falls back to Unicode monitor emoji)
- **Display detection**: Refreshes display list each time the menu opens
- **Auto-load**: Loads last-used preset per display on launch
- **LUT debouncing**: 50ms timer prevents excessive `CGSetDisplayTransferByTable` calls during slider drag
- **Menu structure**: Header > Display selector > Brightness slider > Contrast slider > Preset dropdown > Show/Hide DisplayTuner > Reset Display > Quit
- **Same safety guards** as the main app (peak value check, minimum brightness clamp)
- **Restores display on quit**: `CGDisplayRestoreColorSyncSettings()` in both `quitApp` and `applicationWillTerminate`

### 7.12 Auto-Reapply

The main app observes `NSApplication.didChangeScreenParametersNotification` and re-applies the current LUT after a 1.5-second delay. This handles:
- Display wake from sleep
- Resolution changes
- Display reconnection
- External display cable re-seat

## 8. LUT Pipeline

The complete processing order for a single entry at index `i` (where `t = i/255`):

```
Step 1:  afterMaster = masterLUT[i]
         (Master curve interpolated from control points)

Step 2:  masterIdx = clamp(afterMaster * 255, 0, 255)
         R = redLUT[masterIdx]
         G = greenLUT[masterIdx]
         B = blueLUT[masterIdx]
         (RGB curves indexed through master output)

Step 3:  identity = t
         cDelta = cyanLUT[i] - identity
         mDelta = magentaLUT[i] - identity
         yDelta = yellowLUT[i] - identity
         kDelta = blackLUT[i] - identity
         R -= (cDelta + kDelta)
         G -= (mDelta + kDelta)
         B -= (yDelta + kDelta)
         (CMYK subtractive: Cyan reduces Red, Magenta reduces Green,
          Yellow reduces Blue, Black reduces all)

Step 4:  R = applyTonalEQ(R, t, master_bands)
         R = applyTonalEQ(R, t, red_bands)
         G = applyTonalEQ(G, t, master_bands)
         G = applyTonalEQ(G, t, green_bands)
         B = applyTonalEQ(B, t, master_bands)
         B = applyTonalEQ(B, t, blue_bands)
         // CMYK tonal EQ applied as subtractive delta
         R -= (cyanEQ + blackEQ)
         G -= (magentaEQ + blackEQ)
         B -= (yellowEQ + blackEQ)
         (12-band Gaussian-weighted adjustment per channel)

Step 5:  (rGain, gGain, bGain) = bradfordGains(6504, whitePointKelvin)
         R *= rGain
         G *= gGain
         B *= bGain
         (Bradford chromatic adaptation)

Step 6:  if |targetGamma - 2.2| > 0.001:
             gammaExp = targetGamma / 2.2
             R = pow(R, gammaExp)  // for R > 0
             G = pow(G, gammaExp)
             B = pow(B, gammaExp)
         (Gamma correction relative to standard 2.2)

Step 7:  if |brightness - 1.0| > 0.001:
             brGamma = 1.0 / brightness
             R = pow(R, brGamma)  // for R > 0
             G = pow(G, brGamma)
             B = pow(B, brGamma)
         (Quick brightness via gamma shift)

Step 8:  if |contrast - 1.0| > 0.001:
             R = clamp(0.5 + (R - 0.5) * contrast, 0, 1)
             G = clamp(0.5 + (G - 0.5) * contrast, 0, 1)
             B = clamp(0.5 + (B - 0.5) * contrast, 0, 1)
         (Quick contrast via linear S-curve around 0.5)

Step 9:  if |hue| > 0.001 or |saturation - 1.0| > 0.001:
             (H, S, L) = rgb_to_hsl(R, G, B)
             H += hue
             S *= saturation
             (R, G, B) = hsl_to_rgb(H, S, L)
         (Hue rotation and saturation scaling in HSL space)

Step 10: R = clamp(R, 0, 1)
         G = clamp(G, 0, 1)
         B = clamp(B, 0, 1)
         (Range enforcement)

Step 11: if i > 0:
             R = max(0.03, R)
             G = max(0.03, G)
             B = max(0.03, B)
         (Safety floor -- prevents blackout for all non-zero inputs)
```

## 9. Data Model

### 9.1 PresetData (JSON Schema)

```json
{
  "curves": {
    "0": [{"x": 0, "y": 0}, {"x": 1, "y": 1}],
    "1": [{"x": 0, "y": 0}, {"x": 1, "y": 1}],
    "2": [{"x": 0, "y": 0}, {"x": 1, "y": 1}],
    "3": [{"x": 0, "y": 0}, {"x": 1, "y": 1}],
    "4": [{"x": 0, "y": 0}, {"x": 1, "y": 1}],
    "5": [{"x": 0, "y": 0}, {"x": 1, "y": 1}],
    "6": [{"x": 0, "y": 0}, {"x": 1, "y": 1}],
    "7": [{"x": 0, "y": 0}, {"x": 1, "y": 1}]
  },
  "tonalEQ": {
    "bands": {
      "0": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      "1": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      "2": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      "3": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      "4": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      "5": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      "6": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      "7": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    }
  },
  "whitePointKelvin": 6500,
  "previewOn": true,
  "targetGamma": 2.2
}
```

**Key mappings**:
- `curves`: Dictionary keyed by `CurveChannel.rawValue` (0=Master, 1=Red, 2=Green, 3=Blue, 4=Cyan, 5=Magenta, 6=Yellow, 7=Black)
- `tonalEQ.bands`: Dictionary keyed by channel rawValue, each value is an array of 12 doubles (band 0 through 11)

### 9.2 CurvePoint

```swift
struct CurvePoint: Codable {
    var x: CGFloat  // 0.0 - 1.0 (input luminance)
    var y: CGFloat  // 0.0 - 1.0 (output luminance)
}
```

### 9.3 TonalEQState

```swift
struct TonalEQState: Codable {
    var bands: [Int: [Double]]  // channel rawValue -> 12 band values (-1.0 to 1.0)
}
```

### 9.4 UndoState

```swift
struct UndoState {
    var curves: [Int: [CurvePoint]]
    var tonalBands: [Int: [Double]]
    var whitePointKelvin: Double
    var targetGamma: Double
}
```

Note: `UndoState` is not `Codable` -- it exists only in memory during a session.

### 9.5 LastPresetMap

```swift
struct LastPresetMap: Codable {
    var displays: [String: String]  // displayName -> settingName
}
```

### 9.6 DisplayInfo (Menu Bar App)

```swift
struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String   // Resolution-based, e.g. "3840x2160" (for preset matching)
    let label: String  // Friendly name, e.g. "SAMSUNG", "Cinema HD" (for UI)
    let width: Int
    let height: Int
    let isMain: Bool
}
```

## 10. Safety Requirements

### 10.1 No Changes on Startup

The `userHasInteracted` flag starts as `false`. No call to `CGSetDisplayTransferByTable` is made until this flag becomes `true`, which requires explicit user action:
- Dragging a curve point
- Moving a tonal EQ slider
- Changing the white point
- Loading a preset
- Using an eyedropper
- Performing a color match

### 10.2 Minimum Brightness Clamp

For every LUT index > 0, all three channel values are clamped to a minimum of 0.03:

```swift
if i > 0 {
    r = max(0.03, r)
    g = max(0.03, g)
    b = max(0.03, b)
}
```

Index 0 (pure black) is allowed to remain at 0.0. This ensures that even aggressive curves cannot produce a completely dark display.

### 10.3 Peak Value Sanity Check

Before applying any LUT to the display, the maximum value across all 256 entries is checked for each channel:

```swift
guard let rMax = rTable.max(), let gMax = gTable.max(), let bMax = bTable.max(),
      rMax >= 0.1, gMax >= 0.1, bMax >= 0.1 else {
    return  // silently reject
}
```

This prevents catastrophically dark LUTs from being applied.

### 10.4 Display Restore on Exit

`CGDisplayRestoreColorSyncSettings()` is called in:
- `windowWillClose` (main app window close -- note: app stays running)
- `applicationWillTerminate` (app quit)
- `quitFromStatusBar` (status bar quit action)
- SIGTERM signal handler
- SIGINT signal handler
- `resetDisplay` (menu bar app reset)
- `quitApp` (menu bar app quit)
- `togglePreview` when turning OFF (applies identity LUT to target display only)

### 10.5 Target Display Lock

The target display ID is locked on first user interaction:

```swift
if targetDisplayID == 0 {
    targetDisplayID = selectedDisplayID
}
```

This prevents accidentally sending gamma tables to the wrong display if the user changes the display dropdown mid-session. To target a different display, the user must Reset All first.

## 11. Color Math

### 11.1 sRGB Linearization

```
srgbToLinear(c):
    if c <= 0.04045: return c / 12.92
    else:            return pow((c + 0.055) / 1.055, 2.4)

linearToSRGB(c):
    if c <= 0.0031308: return c * 12.92
    else:              return 1.055 * pow(c, 1/2.4) - 0.055
```

### 11.2 sRGB to XYZ (D65)

```
M_sRGB_to_XYZ = [[0.4124564, 0.3575761, 0.1804375],
                  [0.2126729, 0.7151522, 0.0721750],
                  [0.0193339, 0.1191920, 0.9503041]]
```

### 11.3 XYZ to CIE L*a*b*

Reference illuminant: D50 (X=0.95047, Y=1.0, Z=1.08883)

```
f(t):
    if t > 0.008856: return t^(1/3)
    else:            return (903.3 * t + 16) / 116

L = 116 * f(Y/Yn) - 16
a = 500 * (f(X/Xn) - f(Y/Yn))
b = 200 * (f(Y/Yn) - f(Z/Zn))
```

### 11.4 CIEDE2000

Implementation follows Sharma, Wu, and Dalal (2005). Key steps:
1. Compute chroma C* from a* and b*
2. Calculate G factor for a' adjustment: `G = 0.5 * (1 - sqrt(Cab^7 / (Cab^7 + 25^7)))`
3. Adjust a' values and recompute C' and h'
4. Compute delta L', delta C', delta H'
5. Compute weighting functions SL, SC, SH with rotation term RT
6. Final distance: `sqrt((dL'/SL)^2 + (dC'/SC)^2 + (dH'/SH)^2 + RT*(dC'/SC)*(dH'/SH))`

### 11.5 Bradford Chromatic Adaptation

Simplified diagonal adaptation (per-channel gains rather than full 3x3 matrix transformation):

```
gains(source_K, dest_K):
    (sx, sy) = kelvin_to_xy(source_K)
    (dx, dy) = kelvin_to_xy(dest_K)
    src_XYZ = xy_to_XYZ(sx, sy)
    dst_XYZ = xy_to_XYZ(dx, dy)
    src_cone = M_bradford * src_XYZ
    dst_cone = M_bradford * dst_XYZ
    return (dst_cone / src_cone) per channel
```

### 11.6 HSL Color Space Conversion

Used by the Hue and Saturation quick adjust sliders. Standard RGB-to-HSL and HSL-to-RGB conversion.

## 12. ICC Profile Format

### Binary Structure (v2.4)

```
Offset  Size  Content
------  ----  -------
0       4     Profile size (big-endian uint32)
4       4     Preferred CMM: "appl"
8       4     Version: 0x02400000 (v2.4.0)
12      4     Device class: "mntr" (monitor)
16      4     Color space: "RGB "
20      4     PCS: "XYZ "
24      12    Date/time (6 x uint16)
36      4     Signature: "acsp"
40      4     Platform: "APPL"
44      4     Flags: 0x00000000
48      4     Manufacturer: "none"
52      4     Model: "none"
56      8     Device attributes: all zeros
64      4     Rendering intent: 0 (perceptual)
68      12    PCS illuminant: D50 XYZ (s15Fixed16)
80      4     Creator: "appl"
84      16    Profile ID: zeros
100     28    Reserved: zeros
128     4     Tag count (uint32)
132     n*12  Tag table (n entries: sig + offset + size)
...           Tag data blocks (padded to 4-byte boundaries)
```

### vcgt Tag Structure

```
Offset  Size  Content
------  ----  -------
0       4     Signature: "vcgt"
4       4     Reserved: 0x00000000
8       4     Type: 0 (table-based, not formula)
12      2     Channels: 3
14      2     Entry count: 256
16      2     Entry size: 2 (bytes per entry)
18      512   Red channel (256 x uint16, big-endian)
530     512   Green channel (256 x uint16, big-endian)
1042    512   Blue channel (256 x uint16, big-endian)
```

Total vcgt tag size: 1554 bytes (padded to 1556 for 4-byte alignment).

## 13. UI Layout

### Main Window

- **Dimensions**: 1100 x 950 pixels (minimum 1000 x 900)
- **Background**: calibrated white 0.16

```
+--[ Top Bar (38px) ]--------------------------------------------+
| Display: [dropdown]  Warm-up: 20:00              LIVE/OFF      |
+----------------------------------------------------------------+
|                              |                                  |
|  [M] [R] [G] [B] | [C]     |  [Pick Black] [Pick White]       |
|  [M] [Y] [K]               |  [Pick Gray]                      |
|                              |                                  |
|  +-- Curve Grid --+         |  [Preview ON/OFF] [Undo] [Redo]  |
|  | 520 x 520      |         |  [x] Enhanced Precision           |
|  |                |         |  --------------------------------- |
|  |                |         |  Preset                            |
|  |                |         |  [dropdown] [folder]               |
|  |                |         |  --------------------------------- |
|  |                |         |  Cross-Display Calibration         |
|  |                |         |  Reference: [dropdown]             |
|  |                |         |  [Match Color] [Quick Match]       |
|  |                |         |  [Done Matching]                   |
|  |                |         |  Status: Ready                     |
|  +----------------+         |  Pairs matched: 0                  |
|  Click to add...            |  --------------------------------- |
|                              |  Quick Adjust                     |
|                              |  Brightness: [-----o-----] 1.00  |
|                              |  Contrast:   [-----o-----] 1.00  |
|                              |  Hue:        [-----o-----] 0.00  |
|                              |  Saturation: [-----o-----] 1.00  |
|                              |  --------------------------------- |
|                              |  White Point                      |
|                              |  [D50] [D55] [D65] [D75]         |
|                              |  Kelvin: [----o--------] 6500K   |
|                              |  Gamma:  [------o------] 2.20    |
|                              |  --------------------------------- |
|                              |  [Reset All] [Export ICC]         |
|                              |  [Export .cube] [Test Patterns]   |
|                              |  [Launch Menu Bar App]            |
+----------------------------------------------------------------+
|  Tonal EQ  [M] [R] [G] [B] [C] [M] [Y] [K]                   |
|  +--12 vertical faders (160px height)------------------------+ |
|  | Blk DSh Shd LSh LMd MLo Mid MHi HMd Hlt HLt PkW         | |
|  +-----------------------------------------------------------+ |
+----------------------------------------------------------------+
```

### Right Panel

- Starts at x=560, width = windowWidth - 560 - 15
- Controls stacked vertically with separator lines between sections

## 14. Build & Deployment

### Compile Commands

```bash
# Main application
swiftc -O Sources/DisplayTunerV3.swift \
    -o DisplayTuner \
    -framework AppKit \
    -framework CoreImage \
    -framework QuartzCore

# Menu bar daemon
swiftc -O Sources/DisplayTunerMenuBar.swift \
    -o DisplayTunerMenuBar \
    -framework AppKit
```

### Code Signing

```bash
codesign --force --deep --sign - DisplayTuner
codesign --force --deep --sign - DisplayTunerMenuBar
```

For distribution with a Developer ID:
```bash
codesign --force --deep --sign "Developer ID Application: Your Name" DisplayTuner
```

### .app Bundle Structure

```
DisplayTuner.app/
    Contents/
        Info.plist
        MacOS/
            DisplayTuner
        Resources/
            (optional: app icon)
```

Minimum `Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.emanuelarruda.displaytuner</string>
    <key>CFBundleExecutable</key>
    <string>DisplayTuner</string>
    <key>CFBundleName</key>
    <string>DisplayTuner</string>
    <key>CFBundleVersion</key>
    <string>3.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
```

### Installation Locations

| Component | Path |
|-----------|------|
| Binary (default) | `~/.claude/bin/DisplayTuner` |
| Raw Passthrough ICC | `~/Library/ColorSync/Profiles/Raw_Passthrough.icc` |
| Presets | `~/.config/displayctl/presets/` |
| Last preset map | `~/.config/displayctl/last_preset.json` |
| Exported ICC profiles | `~/Library/ColorSync/Profiles/` |

## 15. Testing

### Manual Verification Checklist

#### Curves
- [ ] Add a point by clicking empty space on the curve grid
- [ ] Drag a point and verify the curve updates smoothly
- [ ] Right-click to delete a point (verify minimum 2 points enforced)
- [ ] Switch between all 8 channel tabs and verify points are preserved
- [ ] Drag a point on the Master curve and verify RGB output changes

#### Tonal EQ
- [ ] Move a shadow fader up and verify shadows brighten
- [ ] Move a highlight fader down and verify highlights darken
- [ ] Switch tonal EQ channel tabs and verify values are preserved
- [ ] Set a CMYK tonal EQ value and verify the subtractive effect

#### White Point
- [ ] Click D50 and verify the display becomes warmer
- [ ] Click D75 and verify the display becomes cooler
- [ ] Drag the Kelvin slider and verify continuous change
- [ ] Verify the Kelvin label updates

#### Preview
- [ ] Press Space to toggle Preview ON/OFF
- [ ] Verify no gamma change on fresh launch before any interaction
- [ ] Verify LIVE indicator shows green when active

#### Safety
- [ ] Create an extreme curve that would black out the display
- [ ] Verify the display remains visible (0.03 minimum floor)
- [ ] Quit the app and verify the display returns to normal
- [ ] Force-kill the app (kill -9) -- note: signal handler only catches SIGTERM/SIGINT, not SIGKILL

#### Presets
- [ ] Save a preset with a custom name
- [ ] Verify the JSON file appears in `~/.config/displayctl/presets/`
- [ ] Load the preset and verify all curves/EQ/white point restore
- [ ] Rename the preset and verify the file is renamed on disk
- [ ] Delete the preset and confirm it is removed

#### Export
- [ ] Export ICC and verify the file appears in `~/Library/ColorSync/Profiles/`
- [ ] Select the exported profile in System Settings > Displays
- [ ] Verify the gamma correction is applied without DisplayTuner running
- [ ] Export .cube and open in a text editor to verify the format

#### Cross-Display
- [ ] Select a reference display
- [ ] Use Match Color to pick colors on two displays
- [ ] Verify curve correction points are added
- [ ] Use Quick Match and verify gamma-based correction is applied

#### Menu Bar App
- [ ] Launch the menu bar app and verify the icon appears
- [ ] Adjust brightness slider and verify display changes
- [ ] Select a preset and verify it loads
- [ ] Click Show DisplayTuner to launch the main app
- [ ] Reset display and verify gamma returns to normal

## 16. Known Issues & Limitations

1. **8bpc display pipeline** -- macOS `CGSetDisplayTransferByTable` uses 256 entries (8-bit input). On 8-bit DVI connections, this means no sub-step precision. Temporal dithering partially compensates.

2. **Single gamma table per display** -- If another app (f.lux, Night Shift, Lunar) modifies the gamma table, it overrides DisplayTuner's corrections. There is no way to stack multiple gamma modifications.

3. **D65 source assumption** -- Bradford adaptation assumes the display's native white point is D65. Displays with significantly different native white points will get inaccurate white point targeting.

4. **No persistent daemon** -- The menu bar app must be manually launched. There is no LaunchAgent or Login Item to start it automatically.

5. **BetterDisplay virtual displays** -- These appear in the display list and can cause confusion. The menu bar app filters them out; the main app includes them for mirror calibration workflows.

6. **Quick adjust not in undo** -- Brightness, contrast, hue, and saturation slider values are not captured in the undo stack. Undo only restores curves, tonal EQ, white point, and gamma.

7. **ColorChecker Delta-E is theoretical** -- The Delta-E values shown in the test pattern compare the sRGB approximation of each patch against the published L*a*b* reference. They do not measure the actual display output.

8. **No multi-point white balance** -- White point correction is a single global Kelvin shift. Displays with non-uniform white point across the luminance range (warm shadows, cool highlights) need per-band correction via the tonal EQ CMYK channels.

## 17. Future Work

1. **Cross-display camera calibration** -- Use the Mac's built-in camera or an iPhone to photograph test patterns on both displays, then automatically compute correction curves from the captured images.

2. **LaunchAgent auto-start** -- Create a macOS LaunchAgent plist so the menu bar app starts automatically on login and reapplies the last preset.

3. **Preset sharing** -- Export/import presets as standalone files with display metadata, allowing users to share calibrations for the same display model.

4. **3D LUT at display level** -- If macOS ever exposes a 3D LUT API (or via Metal shader injection), implement true 3D color correction instead of three independent 1D LUTs.

5. **Colorimeter integration** -- Support reading measurements from i1Display Pro or similar hardware to automate the calibration process with closed-loop feedback.

6. **Profile validation** -- After exporting an ICC profile, read it back with ColorSync APIs to verify macOS can parse it correctly.

7. **Web-based preset browser** -- A simple web app where users can upload and download presets for specific display models.
