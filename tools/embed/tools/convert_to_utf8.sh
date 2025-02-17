#!/bin/bash
# Recursively converts text files in a directory from Windows encodings (CP1252, Windows-1252)
# or ISO-8859-1 to UTF-8. Skips already UTF-8 encoded and empty files.
#
# Usage: ./script.sh [input_dir] [debug]
#   input_dir: Directory to process (default: ./input)
#   debug: Enable debug output (default: false)

set -euo pipefail

START_DIR=${1:-./input}
DEBUG=${2:-false}
MAX_SIZE=$((10 * 1024 * 1024))  # 10MB limit

debug() {
    if [ "$DEBUG" = "true" ]; then
        echo "DEBUG: $1" >&2
        hexdump -C "$file" | head -n 5 >&2
    fi
}

detect_bom() {
    local file=$1
    # Check for UTF-8 BOM (EF BB BF)
    if [ "$(head -c 3 "$file" | xxd -p)" = "efbbbf" ]; then
        return 0
    fi
    return 1
}

if [ ! -d "$START_DIR" ]; then
    printf "Error: Directory '%s' does not exist.\n" "$START_DIR" >&2
    exit 1
fi

TEMP_FILE=$(mktemp)
trap 'rm -f "$TEMP_FILE" "$TEMP_FILE.nobom"' EXIT

try_convert() {
    local file=$1
    local from_enc=$2
    local temp=$3
    local perms

    perms=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")

    debug "Trying $from_enc..."

    # Handle BOM if present
    if detect_bom "$file"; then
        debug "BOM detected, removing..."
        tail -c +4 "$file" > "$temp.nobom"
        mv "$temp.nobom" "$file"
    fi

    # translit replaces unmappable chars
    if LC_ALL=C iconv -f "$from_enc" -t UTF-8//TRANSLIT "$file" > "$temp" 2>/dev/null; then
        cat "$temp" > "$file"
        chmod "$perms" "$file"
        return 0
    fi
    return 1
}

while IFS= read -r -d $'\0' FILE; do
    printf "Converting %-50s\n" "${FILE}"

    # Skip empty files
    if [ ! -s "$FILE" ]; then
        echo "[SKIPPED - EMPTY]"
        continue
    fi

    # Skip large files
    if [ "$(stat -f%z "$FILE" 2>/dev/null || stat -c%s "$FILE")" -gt "$MAX_SIZE" ]; then
        echo "[SKIPPED - TOO LARGE]"
        continue
    fi

    # Skip if already UTF-8 without BOM
    if file -bi "$FILE" | grep -q "charset=utf-8"; then
        echo "[SKIPPED - ALREADY UTF-8]"
        continue
    fi

    # try common windows encodings first
    if try_convert "$FILE" "UTF-8" "$TEMP_FILE" || \     # Try UTF-8 first (handles BOM)
       try_convert "$FILE" "UTF-16LE" "$TEMP_FILE" || \  # Common for Windows
       try_convert "$FILE" "UTF-16BE" "$TEMP_FILE" || \  # Less common but possible
       try_convert "$FILE" "KOI8-R" "$TEMP_FILE" || \    # Additional Cyrillic
       try_convert "$FILE" "KOI8-U" "$TEMP_FILE" || \    # Ukrainian Cyrillic
       try_convert "$FILE" "CP1251" "$TEMP_FILE" || \    # Cyrillic Windows
       try_convert "$FILE" "CP1252" "$TEMP_FILE" || \    # Western European Windows
       try_convert "$FILE" "WINDOWS-1252" "$TEMP_FILE" || \
       try_convert "$FILE" "ISO-8859-1" "$TEMP_FILE" || \
       try_convert "$FILE" "ISO-8859-5" "$TEMP_FILE"; then  # Cyrillic ISO
        echo "[OK]"
    else
        echo "[FAILED]"
        if [ "$DEBUG" = "true" ]; then
            debug "Conversion failed. File details:"
            file -i "$FILE" >&2
            debug "First 100 bytes of file:"
            hexdump -C "$FILE" | head -n 5 >&2
        fi
    fi
done < <(find "$START_DIR" -type f -print0)

printf "\nConversion complete.\n"
