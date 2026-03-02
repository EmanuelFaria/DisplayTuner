# Display Calibration Workflow

Step-by-step guide for calibrating an external display using DisplayTuner.

## Phase 1: Environment Preparation

1. **Warm up your display** for at least 20 minutes at normal brightness. LCD backlights drift during warm-up and the colors won't stabilize until the panel reaches operating temperature. DisplayTuner shows a countdown timer.

2. **Control ambient lighting.** Dim overhead lights, close blinds, and eliminate reflections on the display surface. Colored walls or objects behind you reflect onto the screen and affect perception.

3. **Set the Raw Passthrough profile.** Go to System Settings > Displays > select your target display > Color Profile > scroll to "Raw Passthrough." This removes all macOS color management, giving you the display's true output.

## Phase 2: Baseline Assessment

1. **Open the calibration test pattern.** In DisplayTuner, click "Test Patterns" and select "Grayscale Ramp."

2. **Check shadow detail.** Can you distinguish the 1%, 2%, 3%, 4% near-black patches? If they all look the same, your display is crushing shadows.

3. **Check highlight detail.** Can you distinguish 96%, 97%, 98%, 99%? If they merge into white, your highlights are clipping.

4. **Check neutral gray.** Look at the "Neutral 128" patch. Does it have a color tint (pink, green, yellow)? This reveals the display's color cast.

5. **Check the ColorChecker.** Note which patches show high Delta-E values (red numbers). These are your priority areas.

## Phase 3: Calibration

### Quick Method (Eyedropper)

1. Display the grayscale test pattern on the target display
2. Click **Pick Black Point** → click the `0` shadow patch
3. Click **Pick White Point** → click the `255` patch
4. Click **Pick Gray Point** → click the `Neutral 128` patch
5. This sets a basic correction. Fine-tune from here.

### Detailed Method (Curves + EQ)

1. **Master curve:** Adjust overall brightness by dragging the midpoint up (brighter) or down (darker). Keep the endpoints at 0,0 and 1,1 for now.

2. **Remove color cast:** Switch to the channel that's too strong. If neutrals look green, go to the Green tab and pull the midpoint down. If too warm/yellow, pull Red down slightly and boost Blue.

3. **Shadow detail:** On the Master tab, add a point near the bottom-left of the curve. Pull it up slightly to lift the shadows. This recovers detail in dark areas.

4. **Highlight detail:** Add a point near the top-right. Pull it down slightly to prevent highlight clipping.

5. **Tonal EQ:** For targeted adjustments, use the vertical faders. Each band affects a specific brightness range. Pull the "Shadow" fader up to brighten dark tones without affecting midtones.

6. **White point:** If the display is too warm or cool, use the white point presets. D65 (6504K) is the standard for screen work. D50 (5003K) is warmer, used for print proofing.

7. **CMYK curves:** If you're comfortable with CMYK color correction, switch to the C/M/Y/K tabs. Adding cyan reduces red, adding magenta reduces green, adding yellow reduces blue. The K channel darkens all channels equally.

## Phase 4: Verification

1. **A/B compare:** Press Space to toggle between your calibration and the raw display. The calibrated view should look more neutral, with better shadow/highlight detail.

2. **ColorChecker:** Open the Macbeth 24-patch test pattern. Check the Delta-E values:
   - Green (<1.0): Excellent — imperceptible difference from reference
   - Yellow (1.0-3.0): Good — barely perceptible
   - Red (>3.0): Needs work — visually obvious difference

3. **Gamma verification:** Open the alternating-line gamma test. Step back 2-3 feet and squint. The square whose solid gray matches the striped pattern indicates your actual gamma. It should be at or near 2.2.

4. **Real-world test:** Open photos, videos, or web pages you're familiar with and compare between displays.

## Phase 5: Export

1. Click **Export ICC** and enter a descriptive name (e.g., "Cinema HD 30 Calibrated 2026-03")
2. The ICC profile is saved to ~/Library/ColorSync/Profiles/ with a vcgt tag
3. Go to System Settings > Displays > Color Profile and select your new profile
4. The gamma correction now loads automatically whenever this profile is active — DisplayTuner doesn't need to be running

### For video editors

Click **Export .cube** to create a standard 3D LUT file compatible with DaVinci Resolve, Final Cut Pro, and other NLEs. Import this LUT in your color grading workflow.

## Tips

- **Recalibrate monthly.** Display characteristics drift over time, especially on aging CCFLs.
- **Don't chase perfection.** A calibrated 8-bit display will never match a reference monitor. Aim for neutral grays and reasonable Delta-E on the ColorChecker.
- **Trust the process.** If the calibration looks worse than the raw display at first, your eyes may be adapted to the uncorrected colors. Give it 15 minutes.
- **Save presets.** Before exporting, save your curves as a preset. You can reload and tweak later.
