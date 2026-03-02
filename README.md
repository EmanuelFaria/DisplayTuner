# DisplayTuner

Professional display calibration for macOS. Real-time Photoshop-style RGB/CMYK curves, tonal EQ, white point targeting, and ICC profile export with vcgt support.

Built for aging external displays (Apple Cinema HD 30", etc.) where built-in macOS display settings and MonitorControl aren't enough.

## Features

- **8-channel curves** — Master, R, G, B, C, M, Y, K with Photoshop-style control points
- **520x520 curve grid** — Fine-grained control with movable endpoints in both X and Y
- **Tonal EQ** — Audio mixer-style vertical faders for 7 tonal bands per channel
- **White point targeting** — D50/D55/D65/D75 presets + custom Kelvin slider (Bradford CAT)
- **Real-time preview** — Changes apply instantly via CoreGraphics gamma table
- **A/B compare** — Toggle preview ON/OFF with Space bar for instant before/after
- **Undo/Redo** — Cmd+Z / Cmd+Shift+Z with 50-state history
- **Eyedropper** — Pick black, white, and gray points directly from screen
- **ICC export** — Named profiles with vcgt tag (auto-applies on profile selection)
- **3D LUT export** — .cube files for DaVinci Resolve / Final Cut Pro
- **Test patterns** — Grayscale ramps, ColorChecker 24-patch with Delta-E 2000 overlay, gamma verification
- **Sharpening** — Core Image unsharp mask + edge enhancement overlay
- **Safety guards** — No changes on startup, minimum brightness clamp, display restore on quit

## Requirements

- macOS 14+ (Sonoma) on Apple Silicon
- No Xcode required — compiles with `swiftc` from Command Line Tools

## Quick Start

```bash
git clone https://github.com/your-username/DisplayTuner.git
cd DisplayTuner
./Scripts/build.sh
./Scripts/install.sh
```

Then run:
```bash
DisplayTuner
```

## Calibration Workflow

### 1. Prepare

- Let your display warm up for 20 minutes (the app shows a countdown timer)
- Dim ambient lighting and eliminate reflections
- Set your display to the **Raw Passthrough** ICC profile in System Settings > Displays > Color Profile (installed automatically by `install.sh`)

### 2. Calibrate

1. Select your target display in the dropdown
2. Use **Pick Gray Point** on a neutral gray area to remove color cast
3. Adjust the **Master curve** to set overall brightness/contrast
4. Switch to **R/G/B tabs** for per-channel color correction
5. Use the **Tonal EQ** for targeted shadow/midtone/highlight adjustments
6. Set your target **white point** (D65 for general use, D50 for print)
7. Toggle **Preview ON/OFF** (Space bar) to compare with raw display

### 3. Verify

- Open **Test Patterns** and check the ColorChecker — Delta-E values should be green (<1.0) or yellow (<3.0) on neutral patches
- Check the gamma verification squares from arm's length
- Verify shadow detail in the near-black patches

### 4. Export

- Click **Export ICC** and name your profile
- The exported profile includes a `vcgt` tag — macOS automatically applies the gamma correction when you select the profile
- Optionally export a **.cube** file for use in video editing software

## How It Works

DisplayTuner uses the CoreGraphics `CGSetDisplayTransferByTable` API to modify the GPU's gamma lookup table in real-time. This is the same mechanism used by professional calibration tools like DisplayCAL and Lunar.

The LUT pipeline chains:
```
Master curve → Per-channel RGB → CMYK deltas → Tonal EQ → White point → Safety clamp → Display
```

When you export an ICC profile, the LUT is embedded as both TRC (Tone Reproduction Curve) tags and a vcgt (Video Card Gamma Table) tag. The vcgt tag tells macOS to automatically load the gamma correction when the profile is selected — no need to run DisplayTuner after calibration.

### Raw Canvas Mode

Professional calibrators always start from a known baseline. The included **Raw Passthrough** ICC profile (identity gamma, sRGB primaries, no corrections) tells macOS "this display is perfect — don't touch anything." This gives you the display's true, uncorrected output as your starting point.

## Architecture

Single-file native AppKit application. No SwiftUI, no Xcode project, no dependencies.

```
Sources/DisplayTunerV3.swift    # ~3000 lines, the entire app
Scripts/build.sh                # Compile with swiftc
Scripts/install.sh              # Install binary + Raw Passthrough ICC
Scripts/lut_to_icc.py           # ICC profile builder with vcgt tag
Resources/raw_passthrough.icc   # Identity ICC profile for Raw Canvas mode
Resources/colorchecker_lab.json # Macbeth 24-patch L*a*b* reference values
```

## Safety

DisplayTuner was built after accidentally blacking out a Cinema HD by sending bad gamma tables. Safety is built into every layer:

- **No changes on startup** — the `userHasInteracted` flag prevents any gamma modification until you explicitly drag a control
- **Minimum brightness clamp** — LUT entries below 0.03 are clamped (prevents blackout)
- **Sanity check** — tables with peak values below 0.1 are rejected entirely
- **Restore on quit** — `CGDisplayRestoreColorSyncSettings()` called on window close and app termination
- **Signal handler** — catches SIGTERM/SIGINT to restore display even on crash

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Space | Toggle Preview ON/OFF |
| Cmd+Z | Undo |
| Cmd+Shift+Z | Redo |
| Cmd+S | Save preset |
| Cmd+E | Export ICC |
| Cmd+F | Full-screen test pattern |
| Cmd+Q | Quit (restores display) |

## Credits

Built with Claude Code. Calibration math references:
- [Bruce Lindbloom](http://www.brucelindbloom.com/) — color space conversion formulas
- [ArgyllCMS](https://www.argyllcms.com/) — VCGT and calibration workflow patterns
- [DisplayCAL](https://displaycal.net/) — 5-phase calibration methodology
- [X-Rite ColorChecker](https://en.wikipedia.org/wiki/ColorChecker) — published L*a*b* reference values

## License

MIT
