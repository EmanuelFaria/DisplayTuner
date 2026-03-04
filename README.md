# DisplayTuner

Professional display calibration for macOS. Real-time Photoshop-style RGB/CMYK curves, 12-band tonal EQ, white point targeting with Bradford chromatic adaptation, cross-display color matching, and ICC profile export with vcgt support.

Built for aging external displays (Apple Cinema HD 30", etc.) where built-in macOS display settings and MonitorControl are not enough.

<!-- Screenshots go here -->

## Features

### Curves Engine
- **8-channel curves** -- Master, R, G, B, C, M, Y, K with draggable control points
- **520x520 curve grid** with quarter-mark gridlines and identity diagonal reference
- **Monotone cubic Hermite interpolation** (Fritsch-Carlson) for smooth, artifact-free curves
- Click to add points, drag to move, right-click to delete
- Movable endpoints in both X and Y for black/white point control

### Tonal EQ
- **12 bands per channel** covering the full luminance range (Black through Peak White)
- Audio mixer-style vertical faders with Gaussian-weighted influence (sigma = 0.05)
- Independent EQ for all 8 channels (Master, RGB, CMYK)
- Band centers: 2%, 7%, 12%, 20%, 30%, 40%, 50%, 60%, 70%, 80%, 90%, 97%

### White Point & Gamma
- **D50 / D55 / D65 / D75** one-click presets
- Custom Kelvin slider (3200K -- 9300K)
- **Bradford chromatic adaptation transform** for perceptually accurate white point shifts
- Target gamma slider (1.0 -- 3.0), default 2.2

### Quick Adjust
- **Brightness** -- gamma-shift slider (0.5 -- 1.5)
- **Contrast** -- S-curve slider (0.5 -- 2.0)
- **Hue** -- full HSL hue rotation (-0.5 to +0.5)
- **Saturation** -- HSL saturation scaling (0.0 -- 2.0)

### Preview & Compare
- Real-time preview via `CGSetDisplayTransferByTable`
- **A/B compare** -- toggle Preview ON/OFF with Space bar
- LIVE indicator shows when corrections are active
- Auto-enables preview on first interaction

### Undo/Redo
- **50-state undo/redo stack** (Cmd+Z / Cmd+Shift+Z)
- Captures curves, tonal EQ, white point, and gamma state

### Eyedropper
- **Pick Black Point** -- set the black endpoint from a screen sample
- **Pick White Point** -- set the white endpoint from a screen sample
- **Pick Gray Point** -- neutralize color cast at a sampled brightness level

### Export
- **ICC profile export** -- v2.4 profiles with TRC curves, sRGB primaries, and vcgt tag
- **3D LUT export** -- 33x33x33 `.cube` files for DaVinci Resolve and Final Cut Pro
- Profiles saved to `~/Library/ColorSync/Profiles/` for immediate selection in System Settings

### Test Patterns
- Grayscale ramp (21 steps)
- Near-black detail (0% -- 5%)
- Near-white detail (95% -- 100%)
- ColorChecker 24-patch with CIEDE2000 Delta-E overlay (color-coded: green < 1.0, yellow < 3.0, red > 3.0)
- Gamma verification (1.8, 2.0, 2.2, 2.4, 2.6 with checkerboard vs. solid mid-gray)
- RGB primaries + CMY secondaries
- Skin tones (6 patches from Fair to Dark)

### Cross-Display Calibration
- **Match Color** eyedropper -- pick a color on the target display, then pick the same color on the reference display to generate curve correction points
- **Quick Match** -- automated gamma correction based on the reference display's ICC profile TRC data
- Reference display selector for multi-monitor setups

### Safety
- No changes on startup (the `userHasInteracted` flag prevents any gamma modification until you explicitly touch a control)
- Minimum brightness clamp (LUT entries below 0.03 are clamped for indices > 0)
- Sanity check (tables with any channel peak below 0.1 are rejected entirely)
- Display restore on quit (`CGDisplayRestoreColorSyncSettings()` on window close, app termination, SIGTERM, and SIGINT)

### Menu Bar App
- Lightweight daemon that lives in the menu bar
- Per-display brightness and contrast sliders
- Preset dropdown with save/load/rename/delete/browse
- Auto-loads last-used preset per display on launch
- Show/hide the main DisplayTuner window
- Reset display to default

## Requirements

- macOS 14+ (Sonoma) on Apple Silicon or Intel
- Xcode Command Line Tools (`xcode-select --install`)
- Apple Developer certificate (optional, for code signing)

## Quick Start

```bash
git clone https://github.com/emanuelarruda/DisplayTuner.git
cd DisplayTuner
./Scripts/build.sh
./Scripts/install.sh
DisplayTuner
```

## Architecture

DisplayTuner uses a **two-app design**:

| Component | Purpose | Activation Policy |
|-----------|---------|-------------------|
| `DisplayTuner` | Full curve editor with all controls | `.regular` (Dock icon + menu bar) |
| `DisplayTunerMenuBar` | Lightweight daemon for quick adjustments | `.accessory` (menu bar icon only) |

Both are **single-file native AppKit applications**. No SwiftUI, no Xcode project, no dependencies beyond the macOS SDK. Each file compiles directly with `swiftc`:

```bash
swiftc -O Sources/DisplayTunerV3.swift -o DisplayTuner -framework AppKit -framework CoreImage -framework QuartzCore
swiftc -O Sources/DisplayTunerMenuBar.swift -o DisplayTunerMenuBar -framework AppKit
```

The main app stays running in the status bar when the window is closed (`applicationShouldTerminateAfterLastWindowClosed` returns `false`). The menu bar app can launch the main app and vice versa.

## How It Works

DisplayTuner modifies the GPU's gamma lookup table in real-time using the CoreGraphics `CGSetDisplayTransferByTable` API. This is the same mechanism used by professional calibration tools like DisplayCAL and Lunar.

### LUT Pipeline

The 256-entry LUT for each RGB channel is computed through an 11-step pipeline:

```
1. Master curve        -- overall brightness/contrast via cubic Hermite interpolation
2. Per-channel RGB     -- independent R, G, B curve corrections (indexed through master)
3. CMYK deltas         -- subtractive corrections (Cyan reduces Red, etc.)
4. Tonal EQ            -- 12-band Gaussian-weighted brightness per channel
5. White point         -- Bradford chromatic adaptation gains (source=D65, dest=target)
6. Target gamma        -- gamma correction relative to standard 2.2
7. Quick brightness    -- gamma shift: output = input ^ (1/brightness)
8. Quick contrast      -- S-curve: output = 0.5 + (input - 0.5) * contrast
9. Hue/Saturation      -- RGB to HSL, shift hue, scale saturation, HSL to RGB
10. Clamp              -- enforce 0.0 -- 1.0 range
11. Safety clamp       -- enforce minimum 0.03 for indices > 0 (prevents blackout)
```

The result is three 256-entry `Float` arrays (R, G, B) passed to `CGSetDisplayTransferByTable`.

### Enhanced Precision

An optional temporal dithering mode alternates between floor and ceil variants of the LUT on each display refresh (via `CVDisplayLink`), effectively simulating 8.5-bit precision on an 8-bit display pipeline.

## Raw Canvas Mode

Professional calibrators always start from a known baseline. The included **Raw Passthrough** ICC profile (`Resources/raw_passthrough.icc`) is an identity profile with:
- Linear gamma (1.0)
- sRGB primaries
- No corrections

When you assign this profile to your display in System Settings > Displays > Color Profile, it tells macOS "this display is perfect -- don't touch anything." This gives you the display's true, uncorrected output as your starting point for calibration.

The `install.sh` script copies this profile to `~/Library/ColorSync/Profiles/Raw_Passthrough.icc`.

## Calibration Workflow

### 1. Prepare

- Let your display warm up for at least 20 minutes (DisplayTuner shows a countdown timer)
- Dim ambient lighting and eliminate reflections
- Set your display to the **Raw Passthrough** profile in System Settings > Displays > Color Profile

### 2. Baseline Assessment

- Open **Test Patterns** and select **Grayscale Ramp**
- Check shadow detail: can you distinguish the 1%, 2%, 3%, 4% patches?
- Check highlight detail: can you distinguish 96%, 97%, 98%, 99%?
- Check neutral gray: does the 50% patch have a color tint?
- Open the **ColorChecker 24** pattern and note high Delta-E patches

### 3. Calibrate

1. Select your target display in the dropdown
2. Use **Pick Gray Point** on a neutral gray area to remove color cast
3. Adjust the **Master curve** for overall brightness
4. Switch to R/G/B tabs for per-channel color correction
5. Use the **Tonal EQ** for targeted shadow/midtone/highlight adjustments
6. Set your target **white point** (D65 for screen work, D50 for print proofing)
7. Fine-tune with CMYK curves if needed (Cyan reduces red, Magenta reduces green, Yellow reduces blue, Black darkens all equally)

### 4. Verify

- Press **Space** to toggle A/B compare between calibrated and raw
- Check the ColorChecker: green (< 1.0 dE) is excellent, yellow (1-3 dE) is good, red (> 3 dE) needs work
- Check the gamma verification pattern from arm's length -- the correct gamma square blends with its checkerboard
- Open familiar photos and compare across displays

### 5. Export

- Click **Export ICC** and enter a descriptive name
- The ICC profile includes a `vcgt` tag -- macOS automatically applies the gamma correction when the profile is selected, without needing DisplayTuner running
- Optionally click **Export .cube** for a 3D LUT file for video editing software

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Space | Toggle Preview ON/OFF |
| Cmd+Z | Undo |
| Cmd+Shift+Z | Redo |
| Cmd+Q | Quit (restores display) |
| Cmd+W | Close window (app stays in status bar) |
| Cmd+M | Minimize |

## Preset System

Presets are stored as JSON files in `~/.config/displayctl/presets/`. Each preset captures:

- All 8 curve channels (control point positions)
- All 96 tonal EQ band values (8 channels x 12 bands)
- White point Kelvin value
- Target gamma
- Preview state

### File Naming

Preset files are prefixed with the display's resolution to keep presets display-specific:

```
~/.config/displayctl/presets/
    2560x1600-cinema-hd-30-aging.json
    2560x1600-warm-evening.json
    3840x2160-samsung-default.json
```

The display name portion is sanitized (spaces to underscores, parentheses removed).

### Last Preset Tracking

`~/.config/displayctl/last_preset.json` maps each display name to its last-used preset setting name. Both the main app and the menu bar app use this to auto-load the appropriate preset on launch or display switch.

## Cross-Display Calibration

### Match Color (Manual)

1. Click **Match Color** in the Cross-Display Calibration section
2. Use the eyedropper to pick a color on the **target** display (the one you want to calibrate)
3. Then pick the **same** color on the **reference** display (the one you trust)
4. DisplayTuner inserts R/G/B curve correction points mapping the source value to the target value
5. Repeat for multiple colors to build a comprehensive correction
6. Click **Done Matching** when finished

### Quick Match (Automated)

Reads the reference display's ICC profile TRC data (rTRC tag) to extract its gamma curve, then generates 21-point correction curves that make the target display match the reference display's gamma response.

## Test Patterns

Open from the main window via the **Test Patterns** button. Test pattern windows can be created on each connected display and support full-screen mode.

| Pattern | Purpose |
|---------|---------|
| Grayscale Ramp | 21-step ramp from black to white |
| Near-Black (0-5%) | 6 patches for shadow detail verification |
| Near-White (95-100%) | 6 patches for highlight clipping detection |
| ColorChecker 24 | X-Rite Macbeth chart with CIEDE2000 Delta-E overlay |
| Gamma Verify | Checkerboard vs. solid mid-gray at 5 gamma values |
| RGB Primaries | Pure R/G/B and C/M/Y patches |
| Skin Tones | 6 patches from Fair to Dark |

## Menu Bar App

The menu bar app (`DisplayTunerMenuBar`) is a lightweight companion that runs as a menu bar icon. It provides:

- Display selector submenu
- Brightness and contrast sliders (per-display, applied via the same LUT pipeline)
- Preset dropdown with all presets for the selected display
- Save / Rename / Delete preset management
- Browse for preset files
- Open Presets Folder
- Launch or hide the main DisplayTuner window
- Reset display to defaults
- Quit (restores display gamma)

Launch it from the main app via the **Launch Menu Bar App** button, or run it directly:

```bash
DisplayTunerMenuBar
```

## Safety

DisplayTuner was built after accidentally blacking out a Cinema HD by sending bad gamma tables. Safety is built into every layer:

| Guard | Mechanism |
|-------|-----------|
| **No changes on startup** | The `userHasInteracted` flag prevents any gamma modification until you explicitly drag a control or load a preset |
| **Minimum brightness clamp** | LUT entries for indices > 0 are clamped to a floor of 0.03 (prevents blackout) |
| **Peak value sanity check** | Tables where any channel's peak value is below 0.1 are rejected entirely |
| **Restore on quit** | `CGDisplayRestoreColorSyncSettings()` called on window close, app termination, SIGTERM, and SIGINT |

Additionally, the target display is **locked on first interaction** to prevent accidentally sending gamma tables to the wrong display if the user changes the dropdown mid-session.

## Building from Source

### Prerequisites

```bash
# Install Xcode Command Line Tools
xcode-select --install
```

### Build

```bash
# Build the main app
swiftc -O Sources/DisplayTunerV3.swift -o DisplayTuner \
    -framework AppKit -framework CoreImage -framework QuartzCore

# Build the menu bar daemon
swiftc -O Sources/DisplayTunerMenuBar.swift -o DisplayTunerMenuBar \
    -framework AppKit
```

Or use the build script:

```bash
./Scripts/build.sh
```

### Install

```bash
./Scripts/install.sh
```

This copies the binary to `~/.claude/bin/` (or a custom path as the first argument) and installs the Raw Passthrough ICC profile to `~/Library/ColorSync/Profiles/`.

### Code Signing (optional)

```bash
codesign --force --deep --sign - DisplayTuner
codesign --force --deep --sign - DisplayTunerMenuBar
```

### .app Bundle Structure

If packaging as a macOS application bundle:

```
DisplayTuner.app/
  Contents/
    MacOS/
      DisplayTuner
    Info.plist
    Resources/
```

## File Structure

```
DisplayTuner/
    Sources/
        DisplayTunerV3.swift         # Main app (~3660 lines, the entire application)
        DisplayTunerMenuBar.swift    # Menu bar daemon (~1086 lines)
    Scripts/
        build.sh                     # Compile with swiftc
        install.sh                   # Install binary + ICC profile
        lut_to_icc.py                # Standalone ICC profile builder with vcgt tag
    Resources/
        raw_passthrough.icc          # Identity ICC profile for Raw Canvas mode
        colorchecker_lab.json        # X-Rite Macbeth 24-patch L*a*b* reference (D50)
    Docs/
        calibration-workflow.md      # Detailed 5-phase calibration guide
    LICENSE                          # MIT
    README.md                        # This file
```

## Known Limitations

- **8bpc DVI constraint** -- External displays connected via DVI or HDMI adapters are limited to 8 bits per channel. The gamma table is 256 entries. Temporal dithering can partially compensate.
- **No per-pixel sharpening** -- The gamma LUT operates on the transfer function, not on individual pixels. Sharpening via Core Image is possible but runs as a window overlay, not a display-wide correction.
- **BetterDisplay conflicts** -- BetterDisplay creates virtual displays that appear in the display list. DisplayTuner filters out displays with "Virtual" in the name (menu bar app) but includes them in the main app for mirror calibration workflows.
- **Single LUT per display** -- macOS only supports one gamma table per display. If another app (f.lux, Night Shift, Lunar) modifies the gamma table, it will override DisplayTuner's corrections.
- **No hardware DDC/CI** -- DisplayTuner does not control the display's OSD settings (hardware brightness, contrast, etc.). It only modifies the software gamma ramp.
- **Display lock** -- The target display is locked on first interaction. To switch displays, use Reset All first.
- **No auto-save** -- Preset saving is manual. Changes are lost if you quit without saving.
- **D65 source assumption** -- Bradford adaptation assumes the display's native white point is D65 (6504K). Displays with significantly different native white points may need manual correction.

## Version History

- **v1** -- Basic gamma curve editor, single channel
- **v2** -- Added RGB curves, white point, preset system
- **v3** -- 8-channel CMYK curves, 12-band tonal EQ, cross-display calibration, ICC/cube export, test patterns, menu bar app, safety system, hue/saturation, temporal dithering

## Credits

Built with [Claude Code](https://claude.com/claude-code). Color math references:
- [Bruce Lindbloom](http://www.brucelindbloom.com/) -- color space conversion formulas
- [Sharma et al. (2005)](https://doi.org/10.1002/col.20070) -- CIEDE2000 color difference formula
- [ArgyllCMS](https://www.argyllcms.com/) -- vcgt tag format and calibration workflow patterns
- [DisplayCAL](https://displaycal.net/) -- calibration methodology
- [X-Rite ColorChecker](https://en.wikipedia.org/wiki/ColorChecker) -- published L*a*b* reference values (D50 illuminant)
- [ICC Specification](https://www.color.org/specification/ICC.1-2022-05.pdf) -- profile format

## License

MIT License. Copyright (c) 2026 Emanuel Arruda. See [LICENSE](LICENSE) for details.
