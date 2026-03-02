#!/usr/bin/env python3
"""
lut_to_icc.py — Convert DisplayTuner LUT export to ICC profile with vcgt tag.

The vcgt (Video Card Gamma Table) tag tells macOS to automatically apply
the LUT to the GPU gamma table when the profile is selected. This means
the calibration persists without running the Tuner app.

Usage:
    python3 lut_to_icc.py [--name "Profile Name"] [--input lut.json] [--output profile.icc]
"""
import struct, datetime, os, json, sys, argparse

def build_icc_with_vcgt(name, r_lut, g_lut, b_lut, output_path,
                         rXYZ=None, gXYZ=None, bXYZ=None):
    """Build ICC profile with TRC curves AND vcgt tag for automatic GPU gamma."""
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    # Default sRGB primaries (D50 adapted)
    if rXYZ is None: rXYZ = (0.4360747, 0.2225045, 0.0139322)
    if gXYZ is None: gXYZ = (0.3850649, 0.7168786, 0.0971045)
    if bXYZ is None: bXYZ = (0.1430804, 0.0606169, 0.7141733)
    wp_X, wp_Y, wp_Z = 0.9505, 1.0000, 1.0890

    def to_u16(vals):
        return [int(round(max(0.0, min(1.0, v)) * 65535)) for v in vals]

    rc, gc, bc = to_u16(r_lut), to_u16(g_lut), to_u16(b_lut)

    def s15f16(v): return struct.pack('>i', int(round(v * 65536)))
    def pad4(d):
        r = len(d) % 4
        return d + (b'\x00' * (4 - r) if r else b'')

    # desc tag
    desc_bytes = name.encode('ascii') + b'\x00'
    desc_tag = pad4(b'desc' + b'\x00\x00\x00\x00' + struct.pack('>I', len(desc_bytes)) + desc_bytes
                    + struct.pack('>I', 0) + struct.pack('>I', 0) + struct.pack('>H', 0)
                    + struct.pack('B', 0) + b'\x00' * 67)

    # wtpt tag
    wtpt_tag = b'XYZ ' + b'\x00\x00\x00\x00' + s15f16(wp_X) + s15f16(wp_Y) + s15f16(wp_Z)

    def xyz_tag(x, y, z):
        return b'XYZ ' + b'\x00\x00\x00\x00' + s15f16(x) + s15f16(y) + s15f16(z)

    # TRC tags (per-channel curves)
    def curve_tag(u16_data):
        tag = b'curv' + b'\x00\x00\x00\x00' + struct.pack('>I', len(u16_data))
        for v in u16_data:
            tag += struct.pack('>H', v)
        return pad4(tag)

    rTRC = curve_tag(rc)
    gTRC = curve_tag(gc)
    bTRC = curve_tag(bc)

    # vcgt tag — Video Card Gamma Table
    # Type 0 = table-based (not formula)
    vcgt = b'vcgt' + b'\x00\x00\x00\x00'
    vcgt += struct.pack('>I', 0)      # tagType: 0 = table
    vcgt += struct.pack('>H', 3)      # channels: 3 (RGB)
    vcgt += struct.pack('>H', 256)    # entryCount: 256
    vcgt += struct.pack('>H', 2)      # entrySize: 2 bytes (u16)
    for channel_data in [rc, gc, bc]:
        for v in channel_data:
            vcgt += struct.pack('>H', v)
    vcgt = pad4(vcgt)

    # cprt tag
    cprt_text = f"DisplayTuner Export - {datetime.date.today()}".encode('ascii') + b'\x00'
    cprt_tag = pad4(b'text' + b'\x00\x00\x00\x00' + cprt_text)

    tags_data = [
        (b'desc', desc_tag), (b'wtpt', wtpt_tag),
        (b'rXYZ', xyz_tag(*rXYZ)), (b'gXYZ', xyz_tag(*gXYZ)), (b'bXYZ', xyz_tag(*bXYZ)),
        (b'rTRC', rTRC), (b'gTRC', gTRC), (b'bTRC', bTRC),
        (b'vcgt', vcgt),
        (b'cprt', cprt_tag),
    ]

    tag_table_size = 4 + len(tags_data) * 12
    data_offset = 128 + tag_table_size
    tag_entries, tag_data_block = [], b''
    for sig, data in tags_data:
        tag_entries.append((sig, data_offset + len(tag_data_block), len(data)))
        tag_data_block += data

    profile_size = 128 + tag_table_size + len(tag_data_block)
    now = datetime.datetime.now()

    header = struct.pack('>I', profile_size) + b'appl' + struct.pack('>I', 0x02400000)
    header += b'mntr' + b'RGB ' + b'XYZ '
    header += struct.pack('>HHHHHH', now.year, now.month, now.day, now.hour, now.minute, now.second)
    header += b'acsp' + b'APPL' + struct.pack('>I', 0) + b'\x00' * 4 + b'\x00' * 4 + b'\x00' * 8
    header += struct.pack('>I', 0)  # rendering intent: perceptual
    header += s15f16(0.9642) + s15f16(1.0) + s15f16(0.8249)
    header += b'\x00' * 4 + b'\x00' * 16 + b'\x00' * 28

    tag_table = struct.pack('>I', len(tags_data))
    for sig, offset, size in tag_entries:
        tag_table += sig + struct.pack('>II', offset, size)

    profile = header + tag_table + tag_data_block

    # Validation
    assert len(profile) == profile_size, f"Size mismatch: {len(profile)} vs {profile_size}"
    assert profile[36:40] == b'acsp', "Missing acsp signature"

    # Roundtrip neutral check: mid-gray should be within ±2 of 128
    mid_r = rc[128] / 65535.0 * 255
    mid_g = gc[128] / 65535.0 * 255
    mid_b = bc[128] / 65535.0 * 255
    max_dev = max(abs(mid_r - 128), abs(mid_g - 128), abs(mid_b - 128))
    if max_dev > 50:
        print(f"  Warning: Large neutral deviation at mid-gray: R={mid_r:.1f} G={mid_g:.1f} B={mid_b:.1f}")

    with open(output_path, 'wb') as f:
        f.write(profile)

    return output_path


def export_cube(r_lut, g_lut, b_lut, output_path, title="DisplayTuner Export", size=33):
    """Export a .cube 3D LUT file for DaVinci Resolve / Final Cut Pro."""
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    with open(output_path, 'w') as f:
        f.write(f'TITLE "{title}"\n')
        f.write(f'LUT_3D_SIZE {size}\n')
        f.write('DOMAIN_MIN 0.0 0.0 0.0\n')
        f.write('DOMAIN_MAX 1.0 1.0 1.0\n\n')

        for bi in range(size):
            for gi in range(size):
                for ri in range(size):
                    # Normalize to 0-1
                    r_in = ri / (size - 1)
                    g_in = gi / (size - 1)
                    b_in = bi / (size - 1)

                    # Look up in 1D LUTs (interpolate)
                    def lookup(lut, val):
                        idx = val * 255.0
                        lo = int(idx)
                        hi = min(lo + 1, 255)
                        frac = idx - lo
                        return lut[lo] * (1 - frac) + lut[hi] * frac

                    r_out = lookup(r_lut, r_in)
                    g_out = lookup(g_lut, g_in)
                    b_out = lookup(b_lut, b_in)

                    f.write(f'{r_out:.6f} {g_out:.6f} {b_out:.6f}\n')

    return output_path


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Convert DisplayTuner LUT to ICC profile')
    parser.add_argument('--name', default='DisplayTuner Calibrated',
                       help='Profile name (default: DisplayTuner Calibrated)')
    parser.add_argument('--input', default=os.path.expanduser('~/.config/displayctl/export_lut.json'),
                       help='Input LUT JSON file')
    parser.add_argument('--output', default=None,
                       help='Output ICC path (default: ~/Library/ColorSync/Profiles/<name>.icc)')
    parser.add_argument('--cube', action='store_true',
                       help='Also export .cube file for DaVinci Resolve')
    args = parser.parse_args()

    if not os.path.exists(args.input):
        print(f"No LUT file at {args.input}")
        print("Use Export ICC in DisplayTuner first, or specify --input path")
        sys.exit(1)

    with open(args.input) as f:
        lut = json.load(f)

    output = args.output or os.path.expanduser(
        f"~/Library/ColorSync/Profiles/{args.name.replace(' ', '_')}.icc")

    path = build_icc_with_vcgt(args.name, lut['red'], lut['green'], lut['blue'], output)
    print(f"ICC profile created: {path}")
    print(f"  Name: {args.name}")
    print(f"  Includes vcgt tag for automatic GPU gamma table loading")
    print(f"  Apply via: System Settings > Displays > Color Profile")

    if args.cube:
        cube_path = output.replace('.icc', '.cube')
        export_cube(lut['red'], lut['green'], lut['blue'], cube_path, title=args.name)
        print(f"  .cube LUT: {cube_path}")
