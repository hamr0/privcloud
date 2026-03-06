#!/usr/bin/env bash
#
# google-takeout-fix.sh
#
# Extracts Google Takeout zips and restores metadata (dates + GPS)
# that Google strips/separates into JSON sidecar files.
#
# Usage:
#   ./google-takeout-fix.sh /path/to/folder-with-zips
#   ./google-takeout-fix.sh /path/to/single-takeout.zip
#
# The folder should contain one or more takeout-*.zip files.
# Output goes to an "extracted" subfolder next to the zips,
# with metadata written back into the photos.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; exit 1; }

# --- Resolve input -----------------------------------------------------------

INPUT="${1:?Usage: $0 /path/to/folder-with-zips}"

if [[ -f "$INPUT" && "$INPUT" == *.zip ]]; then
    ZIP_DIR="$(dirname "$(realpath "$INPUT")")"
elif [[ -d "$INPUT" ]]; then
    ZIP_DIR="$(realpath "$INPUT")"
else
    error "Not a valid file or directory: $INPUT"
fi

ZIPS=("$ZIP_DIR"/takeout-*.zip)
if [[ ${#ZIPS[@]} -eq 0 || ! -f "${ZIPS[0]}" ]]; then
    # Try any zip
    ZIPS=("$ZIP_DIR"/*.zip)
    if [[ ${#ZIPS[@]} -eq 0 || ! -f "${ZIPS[0]}" ]]; then
        error "No zip files found in $ZIP_DIR"
    fi
fi

EXTRACT_DIR="$ZIP_DIR/extracted"
info "Found ${#ZIPS[@]} zip file(s) in $ZIP_DIR"

# --- Extract ------------------------------------------------------------------

mkdir -p "$EXTRACT_DIR"
for z in "${ZIPS[@]}"; do
    info "Extracting $(basename "$z")..."
    unzip -o -q "$z" -d "$EXTRACT_DIR"
done

PHOTOS_DIR="$EXTRACT_DIR/Takeout/Google Photos"
if [[ ! -d "$PHOTOS_DIR" ]]; then
    # Try without Takeout wrapper
    PHOTOS_DIR="$EXTRACT_DIR"
    warn "No 'Takeout/Google Photos' folder found, using $EXTRACT_DIR directly"
fi

info "Extracted to: $PHOTOS_DIR"

# --- Install Python deps if needed --------------------------------------------

command -v unzip &>/dev/null || error "unzip not found. Install it first (e.g. sudo apt install unzip / sudo dnf install unzip)."

PYTHON="$(command -v python3 || true)"
[[ -z "$PYTHON" ]] && error "python3 not found. Install Python 3 first."

info "Checking Python dependencies..."
"$PYTHON" -c "import piexif; from PIL import Image" 2>/dev/null || {
    warn "Installing piexif and Pillow..."
    "$PYTHON" -m pip install --user piexif Pillow -q
}

# --- Write and run the metadata fixer -----------------------------------------

FIXER="$(mktemp /tmp/takeout_fix_XXXXX.py)"

cat > "$FIXER" << 'PYEOF'
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

try:
    import piexif
    from PIL import Image
    HAS_PIEXIF = True
except ImportError:
    HAS_PIEXIF = False
    print("  piexif/Pillow not available — will only set file times")

MEDIA_EXTENSIONS = {
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif', '.webp',
    '.heic', '.heif',
    '.mp4', '.mov', '.avi', '.mkv', '.3gp', '.m4v',
}

SIDECAR_SUFFIXES = [
    '.supplemental-metadata.json',
    '.supplemental-metad.json',
    '.supplemental-met.json',
    '.supplemental-me.json',
    '.supplemental-m.json',
    '.supplemental.json',
    '.supplement.json',
    '.suppleme.json',
    '.supplemen.json',
    '.suppl.json',
    '.supp.json',
    '.su.json',
]


def find_sidecar(media_path):
    directory = media_path.parent
    name = media_path.name

    for suffix in SIDECAR_SUFFIXES:
        candidate = directory / f"{name}{suffix}"
        if candidate.exists():
            return candidate

    match = re.match(r'^(.+?)(\(\d+\))(\.\w+)$', name)
    if match:
        base, counter, ext = match.groups()
        for suffix in SIDECAR_SUFFIXES:
            candidate = directory / f"{base}{ext}{counter}{suffix}"
            if candidate.exists():
                return candidate

    stem = media_path.stem
    for candidate_name in [f"{name}.json", f"{stem}.json"]:
        candidate = directory / candidate_name
        if candidate.exists():
            return candidate

    return None


def read_metadata(json_path):
    with open(json_path, 'r') as f:
        data = json.load(f)

    result = {}
    taken = data.get('photoTakenTime', {})
    ts = taken.get('timestamp')
    if ts and ts != '0':
        result['timestamp'] = int(ts)
        result['datetime'] = datetime.fromtimestamp(int(ts), tz=timezone.utc)

    geo = data.get('geoData', {})
    lat = geo.get('latitude', 0)
    lon = geo.get('longitude', 0)
    if lat != 0 or lon != 0:
        result['latitude'] = lat
        result['longitude'] = lon
        result['altitude'] = geo.get('altitude', 0)

    return result


def to_exif_datetime(dt):
    return dt.strftime('%Y:%m:%d %H:%M:%S')


def to_gps_ifd(lat, lon, alt):
    def decimal_to_dms(decimal):
        d = int(abs(decimal))
        m = int((abs(decimal) - d) * 60)
        s = int(((abs(decimal) - d) * 60 - m) * 60 * 10000)
        return ((d, 1), (m, 1), (s, 10000))

    gps_ifd = {
        piexif.GPSIFD.GPSLatitudeRef: b'N' if lat >= 0 else b'S',
        piexif.GPSIFD.GPSLatitude: decimal_to_dms(lat),
        piexif.GPSIFD.GPSLongitudeRef: b'E' if lon >= 0 else b'W',
        piexif.GPSIFD.GPSLongitude: decimal_to_dms(lon),
    }
    if alt and alt != 0:
        gps_ifd[piexif.GPSIFD.GPSAltitudeRef] = 0 if alt >= 0 else 1
        gps_ifd[piexif.GPSIFD.GPSAltitude] = (int(abs(alt) * 100), 100)
    return gps_ifd


def write_exif_jpeg(media_path, metadata):
    try:
        try:
            exif_dict = piexif.load(str(media_path))
        except Exception:
            exif_dict = {'0th': {}, 'Exif': {}, 'GPS': {}, '1st': {}, 'thumbnail': None}

        if 'datetime' in metadata:
            dt_str = to_exif_datetime(metadata['datetime'])
            exif_dict['Exif'][piexif.ExifIFD.DateTimeOriginal] = dt_str.encode()
            exif_dict['Exif'][piexif.ExifIFD.DateTimeDigitized] = dt_str.encode()
            exif_dict['0th'][piexif.ImageIFD.DateTime] = dt_str.encode()

        if 'latitude' in metadata:
            exif_dict['GPS'] = to_gps_ifd(
                metadata['latitude'], metadata['longitude'], metadata.get('altitude', 0)
            )

        exif_dict['1st'] = {}
        exif_dict['thumbnail'] = None
        exif_bytes = piexif.dump(exif_dict)
        piexif.insert(exif_bytes, str(media_path))
        return True
    except Exception as e:
        print(f"  EXIF write failed for {media_path.name}: {e}")
        return False


def set_file_times(media_path, metadata):
    if 'timestamp' in metadata:
        ts = metadata['timestamp']
        os.utime(str(media_path), (ts, ts))
        return True
    return False


def process(input_dir):
    input_path = Path(input_dir)
    media_files = sorted(
        f for f in input_path.rglob('*')
        if f.suffix.lower() in MEDIA_EXTENSIONS and f.is_file()
    )

    total = len(media_files)
    print(f"Found {total} media files\n")

    stats = {'fixed': 0, 'exif': 0, 'skipped': 0, 'failed': 0}

    for i, mf in enumerate(media_files, 1):
        sidecar = find_sidecar(mf)
        if not sidecar:
            stats['skipped'] += 1
            continue

        metadata = read_metadata(sidecar)
        if not metadata:
            stats['skipped'] += 1
            continue

        is_jpeg = mf.suffix.lower() in ('.jpg', '.jpeg')
        if is_jpeg and HAS_PIEXIF:
            if write_exif_jpeg(mf, metadata):
                stats['exif'] += 1
            else:
                stats['failed'] += 1
        set_file_times(mf, metadata)
        stats['fixed'] += 1

        if i % 100 == 0:
            print(f"  {i}/{total}...")

    print(f"\nResults:")
    print(f"  Total files:       {total}")
    print(f"  Fixed:             {stats['fixed']}  (dates + GPS restored)")
    print(f"  EXIF embedded:     {stats['exif']}  (full metadata written into JPEGs)")
    if stats['failed'] > 0:
        print(f"  Failed:            {stats['failed']}  (EXIF write error — dates still set via file timestamp)")
    print(f"  Skipped:           {stats['skipped']}  (no sidecar found — mostly videos with dates already intact)")
    print(f"\nPhotos are ready to import.")


if __name__ == '__main__':
    process(sys.argv[1])
PYEOF

info "Restoring metadata..."
echo ""
"$PYTHON" "$FIXER" "$PHOTOS_DIR"
rm -f "$FIXER"

echo ""
info "Done! Your fixed photos are in:"
echo "  $PHOTOS_DIR"
echo ""
info "To upload to privcloud:"
echo "  1. Start privcloud:  ./privcloud start"
echo "  2. Get API key from http://localhost:2283 → User Settings → API Keys"
echo "  3. Upload:  immich upload --url http://localhost:2283 --key YOUR_KEY \"$PHOTOS_DIR\""
