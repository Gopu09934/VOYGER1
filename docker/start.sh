#!/bin/bash
set -euo pipefail

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi
if [ -z "${AUDIO_URL:-}" ]; then
    echo "ERROR: AUDIO_URL is not set"
    echo "The video sources have no audio track, so AUDIO_URL (one or more"
    echo "background music/ambience files) is required. Same format as"
    echo "VIDEO_URL — comma-separated for multiple tracks: url1,url2,url3"
    exit 1
fi

# Subscriber count + live viewer count are optional — if the API creds
# aren't provided, those panel elements just stay blank instead of
# failing the whole stream.
SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
    SHOW_STATS=false
fi

# Moment Voyager 1 is expected to reach one light-day from Earth.
# Override with e.g. VOYAGER_TARGET_UTC="2026-11-18T12:00:00Z" if NASA
# publishes a more precise time. Format must be YYYY-MM-DDTHH:MM:SSZ.
VOYAGER_TARGET_UTC="${VOYAGER_TARGET_UTC:-2026-11-18T00:00:00Z}"

echo "========================================"
echo "Starting 24/7 YouTube Stream (Voyager 1 / One Light-Day)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "Light-day target  : ${VOYAGER_TARGET_UTC}"
echo "========================================"

FONT="font.ttf"

# ---------------------------------------------------------------
# Colour theme: "Deep Space Signal"
#   NAVY   - deep midnight blue, panel / canvas backgrounds
#   CARD   - lighter indigo, card fill
#   GOLD   - Golden Record gold: key values, highlights
#   CYAN   - radio-signal cyan: labels, brackets, progress
#   VIOLET - nebula violet: headers, secondary accents
#   RED    - live / alert red
# GOLD_R/G/B and CYAN_R/G/B are the same colours as plain RGB for
# geq-generated graphics (marker dot, pie chart).
# ---------------------------------------------------------------
NAVY="0x050A1C"
CARD="0x14204A"
GOLD="0xFFC145"
CYAN="0x35D0FF"
VIOLET="0xA97CFF"
RED="0xFF4D6A"
GOLD_R=255; GOLD_G=193; GOLD_B=69
CYAN_R=53;  CYAN_G=208; CYAN_B=255
PIE_REST_R=28; PIE_REST_G=38; PIE_REST_B=72

ASSET_DIR="panel_assets"
INFO_FILE="voyager_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll
CHANNEL_NAME="Technical Talk India"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
HEADLINE_FONTSIZE=21
HEADLINE_LINE_SPACING=9
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))
FACT_FONTSIZE=16
FACT_LINE_SPACING=7
FACT_LINE_H=$((FACT_FONTSIZE + FACT_LINE_SPACING))

# ---------------------------------------------------------------
# Layout: the video stays centered and full-height. A dedicated
# panel sits on EACH side (left = story/headlines, right = live
# telemetry + spacecraft info + fun facts).
# ---------------------------------------------------------------
PANEL_W=333          # width of each side panel
CENTER_X0=$PANEL_W                     # left edge of the video strip
CENTER_W=$((1280 - PANEL_W * 2))       # width of the video strip (614)
RIGHT_X0=$((1280 - PANEL_W))           # left edge of the right panel (947)
TEXT_INSET=33                          # left panel text left-inset
RTEXT_INSET=$((RIGHT_X0 + 33))         # right panel text left-inset
PANEL_TEXT_W=$((PANEL_W - 66))         # usable text width inside a panel

# ---------------------------------------------------------------
# Center strip: 3 stacked bands —
#   Row 1 - the video
#   Row 2 - mission-status info block (live Voyager 1 numbers)
#   Row 3 - an animated "signal" visualization
# ---------------------------------------------------------------
VIDEO_ROW_H=340
INFO_ROW_H=190
GRAPH_ROW_H=$((720 - VIDEO_ROW_H - INFO_ROW_H))
ROW1_Y=0
ROW2_Y=$((VIDEO_ROW_H))
ROW3_Y=$((VIDEO_ROW_H + INFO_ROW_H))
MTEXT_INSET=$((CENTER_X0 + 30))
MVALUE_X=$((MTEXT_INSET + 150))

# Don't show "N watching now" until the live viewer count reaches this
# many — a very low number reads worse than showing nothing at all.
VIEWER_MIN_TO_SHOW=10


#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5
RETRY_DELAY=5
IMAGE_SLIDE_SECONDS="${IMAGE_SLIDE_SECONDS:-25}"

mkdir -p "$ASSET_DIR"

#############################################
# Background audio (one or more tracks, looped)
# Downloaded once and rotated across videos.
#############################################
IFS=',' read -ra RAW_AUDIO_URLS <<< "$AUDIO_URL"
AUDIO_LOCAL_FILES=()
audio_i=0
for au in "${RAW_AUDIO_URLS[@]}"; do
    au="${au#"${au%%[![:space:]]*}"}"
    au="${au%"${au##*[![:space:]]}"}"
    [ -z "$au" ] && continue
    audio_i=$((audio_i + 1))
    dest="bg_audio_track_${audio_i}"
    echo "Downloading background audio track ${audio_i}..."
    if curl -sL --fail -o "$dest" "$au" && [ -s "$dest" ]; then
        AUDIO_LOCAL_FILES+=("$dest")
        echo "  OK ($(du -h "$dest" | cut -f1))"
    else
        echo "  WARNING: failed to download track ${audio_i} — skipping it."
    fi
done

NUM_AUDIO=${#AUDIO_LOCAL_FILES[@]}
AUDIO_AVAILABLE=false
if [ "$NUM_AUDIO" -gt 0 ]; then
    AUDIO_AVAILABLE=true
    echo "Loaded $NUM_AUDIO background audio track(s); rotating across videos."
else
    echo "WARNING: no background audio tracks downloaded — stream will run with silent audio instead."
fi
AUDIO_COUNTER=0

#############################################
# Panel decoration images (small framed thumbnail in the
# Mission Status card, rotating across videos).
# Override with PANEL_IMAGE_URLS="url1,url2,..." to use
# Voyager / Golden Record / Pale Blue Dot pictures
# (NASA images are public domain; keep credit to NASA/JPL-Caltech).
#############################################
if [ -n "${PANEL_IMAGE_URLS:-}" ]; then
    IFS=',' read -ra PANEL_IMAGE_URLS_ARR <<< "$PANEL_IMAGE_URLS"
else
    PANEL_IMAGE_URLS_ARR=(
        "https://github.com/Gopu09934/VOYGER1/releases/download/f/PIA23645_PaleBlueDotRevisited_1600.jpg"
        "https://github.com/Gopu09934/VOYGER1/releases/download/f/PIA23645_PaleBlueDotRevisited_1600.jpg"
        "https://github.com/Gopu09934/VOYGER1/releases/download/f/PIA23645_PaleBlueDotRevisited_1600.jpg"
        "https://github.com/Gopu09934/VOYGER1/releases/download/f/PIA23645_PaleBlueDotRevisited_1600.jpgg"
    )
fi
PANEL_IMAGE_LOCAL_FILES=()
pimg_i=0
for piu in "${PANEL_IMAGE_URLS_ARR[@]}"; do
    piu="${piu#"${piu%%[![:space:]]*}"}"
    piu="${piu%"${piu##*[![:space:]]}"}"
    [ -z "$piu" ] && continue
    pimg_i=$((pimg_i + 1))
    dest="panel_img_${pimg_i}.jpg"
    echo "Downloading panel image ${pimg_i} ($(basename "$piu"))..."
    if curl -sL --fail -o "$dest" "$piu" && [ -s "$dest" ]; then
        PANEL_IMAGE_LOCAL_FILES+=("$dest")
        echo "  OK ($(du -h "$dest" | cut -f1))"
    else
        echo "  WARNING: failed to download panel image ${pimg_i} — skipping it."
    fi
done
NUM_PANEL_IMAGES=${#PANEL_IMAGE_LOCAL_FILES[@]}
PANEL_IMAGES_AVAILABLE=false
if [ "$NUM_PANEL_IMAGES" -gt 0 ]; then
    PANEL_IMAGES_AVAILABLE=true
    echo "Loaded $NUM_PANEL_IMAGES panel thumbnail(s)."
else
    echo "WARNING: no panel thumbnails downloaded — thumbnail slot will stay empty."
fi
PANEL_IMAGE_COUNTER=0

#############################################
# Coordinate-label marker dot (gold with white ring), generated once.
#############################################
DOT_MARKER="dot_marker.png"
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_R}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):g=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_G}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):b=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_B}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):a=(if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=20x20" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error || true
if [ ! -s "$DOT_MARKER" ]; then
    echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################
# Background clock writer
#############################################
date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!

#############################################
# Background subscriber-count writer
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+' || true)
            if [ -n "$COUNT" ]; then
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                echo "WARNING: could not parse subscriberCount from API response. Raw response:"
                echo "$RESP"
                WARNED_ONCE=true
            fi
            sleep 60
        done
    ) &
    SUBS_PID=$!
fi

#############################################
# Background live-viewer-count writer
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/' || true)
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*' || true)
                if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                elif [ -n "$VIEWERS" ]; then
                    printf ' ' > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    LIVE_VIDEO_ID=""
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                fi
            fi
            sleep 30
        done
    ) &
    VIEWERS_PID=$!
fi

#############################################
# Background Voyager 1 telemetry writer
#
# NO network needed — everything is computed locally once per second
# from the light-day target time, Voyager 1's speed and the speed of
# light. Values are ESTIMATES (Voyager 1's speed is treated as a
# constant ~17 km/s; the distance is anchored so it equals exactly
# one light-day at VOYAGER_TARGET_UTC). Writes one small text file per
# value, which drawtext re-reads each frame with reload=1.
#
#   v_dist_km.txt   full distance in km (center card)
#   v_dist_bn.txt   distance in billions of km (right panel)
#   v_pct.txt       % of one light-day covered
#   v_signal.txt    one-way radio signal time (h m s)
#   v_countdown.txt countdown to one light-day / "REACHED"
#   v_met.txt       mission age in days
#############################################
for f in v_dist_km v_dist_bn v_pct v_signal v_countdown v_met; do
    printf ' ' > "$ASSET_DIR/${f}.txt"
done
printf '17.0 km/s'    > "$ASSET_DIR/v_speed.txt"
printf 'X-BAND 8.4 GHZ' > "$ASSET_DIR/v_band.txt"

cat > voyager_telemetry.py << 'PYEOF'
import os
import sys
import time
from datetime import datetime, timezone

ASSET_DIR = sys.argv[1]
TARGET_STR = sys.argv[2]

C_KM_S = 299792.458
LIGHT_DAY_KM = C_KM_S * 86400.0      # about 25.9 billion km
SPEED_KM_S = 17.0                    # Voyager 1 speed, approx.
LAUNCH = datetime(1977, 9, 5, 12, 56, 0, tzinfo=timezone.utc)

try:
    TARGET = datetime.strptime(TARGET_STR, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
except Exception:
    TARGET = datetime(2026, 11, 18, 0, 0, 0, tzinfo=timezone.utc)


def write(name, text):
    tmp = f"{ASSET_DIR}/{name}.tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, f"{ASSET_DIR}/{name}.txt")


while True:
    try:
        now = datetime.now(timezone.utc)
        delta = (now - TARGET).total_seconds()          # negative before target
        dist = LIGHT_DAY_KM + SPEED_KM_S * delta

        write("v_dist_km", f"{dist:,.0f} km")
        write("v_dist_bn", f"{dist / 1e9:.6f} bn km")
        write("v_pct", f"{dist / LIGHT_DAY_KM * 100:.4f} %")

        sig = dist / C_KM_S
        sh, rem = divmod(int(sig), 3600)
        sm, ss = divmod(rem, 60)
        write("v_signal", f"{sh}h {sm:02d}m {ss:02d}s")

        left = -delta
        if left > 0:
            d, rem = divmod(int(left), 86400)
            h, rem = divmod(rem, 3600)
            m, s = divmod(rem, 60)
            write("v_countdown", f"{d}d {h:02d}h {m:02d}m {s:02d}s")
        else:
            write("v_countdown", "ONE LIGHT-DAY REACHED")

        write("v_met", f"{(now - LAUNCH).days:,} days")
    except Exception as e:
        print(f"telemetry cycle failed: {e}", file=sys.stderr)
    time.sleep(1)
PYEOF
python3 voyager_telemetry.py "$ASSET_DIR" "$VOYAGER_TARGET_UTC" 2>/tmp/voyager_telemetry_err.log &
TELEMETRY_PID=$!
echo "Voyager telemetry writer started (local calculation, 1s refresh)."

trap 'kill "$CLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true; kill "$TELEMETRY_PID" 2>/dev/null || true' EXIT

# Fraction of one light-day covered, used (baked in at each video
# start) to fill the right-panel pie chart. Falls back to 0.99.
voyager_fraction() {
    python3 - "$VOYAGER_TARGET_UTC" << 'PY' 2>/dev/null || echo "0.99"
import sys
from datetime import datetime, timezone
C = 299792.458
LD = C * 86400.0
try:
    t = datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
except Exception:
    t = datetime(2026, 11, 18, tzinfo=timezone.utc)
d = LD + 17.0 * (datetime.now(timezone.utc) - t).total_seconds()
print(f"{max(0.0, min(1.0, d / LD)):.5f}")
PY
}

#############################################
# Static panel text (unchanged across videos)
#############################################
printf 'V O Y A G E R   1'                     > "$ASSET_DIR/title1.txt"
printf 'I N T E R S T E L L A R'               > "$ASSET_DIR/title2.txt"
printf 'V O Y A G E R   S T O R Y'             > "$ASSET_DIR/header.txt"
printf 'LIGHT-DAY WATCH'                       > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE to Technical Talk India'     > "$ASSET_DIR/cta.txt"
printf 'DID YOU KNOW'                          > "$ASSET_DIR/fact_label.txt"
printf 'SPACECRAFT'                            > "$ASSET_DIR/instr_label.txt"
printf 'VOYAGER 1'                             > "$ASSET_DIR/instr_title.txt"

#############################################
# Default headline / fact pools (used if voyager_info.txt /
# facts.txt are missing or empty)
#############################################
DEFAULT_HEADLINES=(
    "Voyager 1 is about to reach one light-day from Earth, a first for any human-made object."
    "On November 18, 2026, Voyager 1 will be about 25.9 billion km away, roughly 16.1 billion miles."
    "Radio signals will take about 24 hours to reach the spacecraft."
    "A complete message and reply exchange will take about 48 hours."
    "Voyager 1 launched on September 5, 1977, nearly 50 years ago."
    "It is the farthest human-made object from Earth."
    "Voyager 1 entered interstellar space in 2012."
    "A light-day is the distance light travels in one day, about 25.9 billion km."
    "NASA talks to Voyager 1 through the Deep Space Network of giant radio antennas."
    "The Golden Record aboard Voyager carries sounds and images from Earth."
    "Voyager 1 carries humanity's message beyond our solar system."
    "Nearly 50 years on, humanity's most distant explorer is still sending data home."
)

DEFAULT_FACTS=(
    "One light-day is about 25.9 billion kilometers."
    "Light from Earth now takes about 24 hours to reach Voyager 1."
    "Voyager 1 travels roughly 17 kilometers every second."
    "Voyager 1 launched on September 5, 1977."
    "The Golden Record carries greetings, music and images from Earth."
    "Voyager 1 entered interstellar space in 2012."
    "Sunlight reaches Earth in 8 minutes, but takes about a day to reach Voyager 1."
    "NASA reaches Voyager 1 through the Deep Space Network."
    "Voyager 1 is powered by radioisotope generators, not solar panels."
    "Voyager 1 and Voyager 2 launched just weeks apart in 1977."
    "A round-trip radio message to Voyager 1 now takes roughly two days."
    "Voyager 1 flew past Jupiter in 1979 and Saturn in 1980."
    "In 1990 Voyager 1 took the famous Pale Blue Dot photo of Earth."
    "Voyager 1 is the farthest human-made object from Earth."
)

#############################################
# build_labels_chain: optional callout labels from
# <basename>.labels.txt ("x,y,Label text" per line).
#############################################
build_labels_chain() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    local i idx

    LABELS_CHAIN=""
    LABELS_OUT="[base]"

    local labels_file="${base}.labels.txt"
    if [ ! -f "$labels_file" ]; then
        return 0
    fi

    local xs=() ys=() texts=()
    while IFS=',' read -r x y text; do
        x="$(echo "$x" | tr -d '[:space:]')"
        y="$(echo "$y" | tr -d '[:space:]')"
        text="$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ "$x" =~ ^[0-9]+$ ]] || continue
        [[ "$y" =~ ^[0-9]+$ ]] || continue
        [ -z "$text" ] && continue
        xs+=("$x"); ys+=("$y"); texts+=("$text")
    done < "$labels_file"

    local n=${#xs[@]}
    if [ "$n" -eq 0 ]; then
        echo "NOTICE: $labels_file had no valid lines — skipping labels for this video."
        return 0
    fi
    echo "Using coordinate labels: $labels_file ($n label(s))"

    local BOX_H=42
    local V_OFFSET=70
    local H_OFFSET=40
    local ACCENT_W=4
    local BOX_GAP=10
    local LABEL_FONTSIZE=18
    local LABEL_PAD_L=14
    local LABEL_PAD_R=16
    local AVG_CHAR_W=10
    local BOX_W_MIN=110
    local BOX_W_MAX=260
    local placed_x=() placed_y=() placed_w=()
    local k collision tries

    local split_outs=""
    for ((i = 1; i <= n; i++)); do split_outs+="[dm${i}]"; done
    LABELS_CHAIN+="[1:v]fps=30,split=${n}${split_outs};"

    local prev="base"
    for ((i = 0; i < n; i++)); do
        idx=$((i + 1))
        local x="${xs[$i]}" y="${ys[$i]}" text="${texts[$i]}"
        printf '%s' "$text" > "$ASSET_DIR/label${idx}.txt"

        local box_w=$(( ${#text} * AVG_CHAR_W + ACCENT_W + LABEL_PAD_L + LABEL_PAD_R ))
        [ "$box_w" -lt "$BOX_W_MIN" ] && box_w=$BOX_W_MIN
        [ "$box_w" -gt "$BOX_W_MAX" ] && box_w=$BOX_W_MAX

        local box_y=$((y - V_OFFSET))
        if [ "$box_y" -lt 20 ]; then
            box_y=$((y + V_OFFSET - BOX_H))
        fi
        local box_x=$((x + H_OFFSET))
        if [ $((box_x + box_w)) -gt $((RIGHT_X0 - 10)) ]; then
            box_x=$((x - H_OFFSET - box_w))
        fi
        [ "$box_x" -lt $((CENTER_X0 + 10)) ] && box_x=$((CENTER_X0 + 10))

        tries=0
        while :; do
            collision=false
            for ((k = 0; k < ${#placed_x[@]}; k++)); do
                local px="${placed_x[$k]}" py="${placed_y[$k]}" pw="${placed_w[$k]}"
                if [ $((box_x)) -lt $((px + pw + BOX_GAP)) ] && \
                   [ $((box_x + box_w + BOX_GAP)) -gt $((px)) ] && \
                   [ $((box_y)) -lt $((py + BOX_H + BOX_GAP)) ] && \
                   [ $((box_y + BOX_H + BOX_GAP)) -gt $((py)) ]; then
                    collision=true
                    break
                fi
            done
            [ "$collision" = false ] && break
            box_y=$((box_y + BOX_H + BOX_GAP))
            if [ $((box_y + BOX_H)) -gt 700 ]; then
                box_y=20
            fi
            tries=$((tries + 1))
            [ "$tries" -gt 12 ] && break
        done
        placed_x+=("$box_x")
        placed_y+=("$box_y")
        placed_w+=("$box_w")

        local seg_y_top seg_y_bot
        if [ "$box_y" -gt "$y" ]; then
            seg_y_top=$y; seg_y_bot=$box_y
        else
            seg_y_top=$box_y; seg_y_bot=$y
        fi
        local seg_h=$((seg_y_bot - seg_y_top))
        [ "$seg_h" -lt 2 ] && seg_h=2

        local h_left h_w
        if [ "$box_x" -gt "$x" ]; then
            h_left=$x; h_w=$((box_x - x))
        else
            h_left=$box_x; h_w=$((x - box_x))
        fi
        [ "$h_w" -lt 2 ] && h_w=2

        local n1="lbl${idx}_dot" n2="lbl${idx}_v" n3="lbl${idx}_h" n4="lbl${idx}_bg" n5="lbl${idx}_bar" n6="lbl${idx}_outline" n7="lbl${idx}_txt"

        LABELS_CHAIN+="[${prev}]drawbox=x=${x}:y=${seg_y_top}:w=2:h=${seg_h}:color=${CYAN}@0.85:t=fill[${n2}];"
        LABELS_CHAIN+="[${n2}]drawbox=x=${h_left}:y=${box_y}:w=${h_w}:h=2:color=${CYAN}@0.85:t=fill[${n3}];"
        LABELS_CHAIN+="[${n3}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${NAVY}@0.85:t=fill[${n4}];"
        LABELS_CHAIN+="[${n4}]drawbox=x=${box_x}:y=${box_y}:w=${ACCENT_W}:h=${BOX_H}:color=${GOLD}:t=fill[${n5}];"
        LABELS_CHAIN+="[${n5}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${CYAN}@0.55:t=1[${n6}];"
        LABELS_CHAIN+="[${n6}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/label${idx}.txt:fontcolor=white:fontsize=${LABEL_FONTSIZE}:x=$((box_x + ACCENT_W + LABEL_PAD_L)):y=$((box_y + (BOX_H - LABEL_FONTSIZE) / 2)):${SHADOW}[${n7}];"
        LABELS_CHAIN+="[${n7}][dm${idx}]overlay=x=$((x - 8)):y=$((y - 8)):shortest=1[${n1}];"

        prev="$n1"
    done

    LABELS_OUT="[${prev}]"
    echo "Drew $n label(s) from $labels_file"
}

#############################################
# prepare_video_content: (re)loads headlines + facts for the video
# about to stream and rebuilds BASE_CHAIN / FACT_END to match.
#
# Per-video overrides (basename = video filename without extension):
#   <basename>.headlines.txt
#   <basename>.facts.txt
#   <basename>.wavelength.txt  (single line, shown under VOYAGER 1 in
#                               the right panel, e.g. "Pale Blue Dot, 1990")
#############################################
prepare_video_content() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    local i idx

    if [ "$PANEL_IMAGES_AVAILABLE" = true ]; then
        MID_PANEL_IMG="${PANEL_IMAGE_LOCAL_FILES[$((PANEL_IMAGE_COUNTER % NUM_PANEL_IMAGES))]}"
        PANEL_IMAGE_COUNTER=$((PANEL_IMAGE_COUNTER + 1))
        echo "Mission Status panel thumbnail this video: $MID_PANEL_IMG"
    fi

    RAW_LINES=()
    if [ -f "${base}.headlines.txt" ]; then
        echo "Using curated headlines: ${base}.headlines.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
        done < "${base}.headlines.txt"
    fi
    if [ "${#RAW_LINES[@]}" -eq 0 ]; then
        local pool=()
        if [ -f "$INFO_FILE" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && pool+=("$line")
            done < "$INFO_FILE"
        fi
        [ "${#pool[@]}" -eq 0 ] && pool=("${DEFAULT_HEADLINES[@]}")
        while IFS= read -r line; do
            RAW_LINES+=("$line")
        done < <(printf '%s\n' "${pool[@]}" | shuf)
    fi

    FACTS=()
    if [ -f "${base}.facts.txt" ]; then
        echo "Using curated facts: ${base}.facts.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
        done < "${base}.facts.txt"
    fi
    if [ "${#FACTS[@]}" -eq 0 ]; then
        local fpool=()
        if [ -f "facts.txt" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && fpool+=("$line")
            done < "facts.txt"
        fi
        [ "${#fpool[@]}" -eq 0 ] && fpool=("${DEFAULT_FACTS[@]}")
        while IFS= read -r line; do
            FACTS+=("$line")
        done < <(printf '%s\n' "${fpool[@]}" | shuf)
    fi

    if [ -f "${base}.wavelength.txt" ]; then
        head -n 1 "${base}.wavelength.txt" > "$ASSET_DIR/instr_sub.txt"
    else
        printf 'Humanity most distant explorer, beyond the solar system' > "$ASSET_DIR/instr_sub.txt"
    fi
    fold -s -w 26 "$ASSET_DIR/instr_sub.txt" > "$ASSET_DIR/instr_sub.wrapped.txt"

    N=${#RAW_LINES[@]}
    CYCLE=$((N * SLOT))
    echo "This video: $N headline(s), rotation cycle ${CYCLE}s"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
    done

    MAX_HEADLINE_LINES=1
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        lines=$(grep -c '' "$ASSET_DIR/headline${idx}.txt")
        [ "$lines" -gt "$MAX_HEADLINE_LINES" ] && MAX_HEADLINE_LINES=$lines
    done
    echo "Longest headline wraps to $MAX_HEADLINE_LINES line(s)."

    # ---- Left panel vertical rhythm ----
    HEADLINE_Y=230
    PROGRESS_Y=$((HEADLINE_Y + MAX_HEADLINE_LINES * HEADLINE_LINE_H + 40))
    DOTS_Y=$((PROGRESS_Y + 20))

    TICKER_STRING=""
    for i in "${!RAW_LINES[@]}"; do
        TICKER_STRING+="${RAW_LINES[$i]}     •     "
    done
    printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

    FACT_N=${#FACTS[@]}
    FACT_CYCLE=$((FACT_N * FACT_SLOT))
    local max_fact_lines=1
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        echo "${FACTS[$i]}" | fold -s -w 24 > "$ASSET_DIR/fact${idx}.txt"
        lines=$(grep -c '' "$ASSET_DIR/fact${idx}.txt")
        [ "$lines" -gt "$max_fact_lines" ] && max_fact_lines=$lines
    done
    MAX_FACT_LINES=$max_fact_lines

    # ---- Right panel vertical rhythm ----
    RSTAT_Y=19
    RDIV1_Y=$((RSTAT_Y + 4 * 20 + 6))
    RINSTR_LABEL_Y=$((RDIV1_Y + 20))
    RINSTR_TITLE_Y=$((RINSTR_LABEL_Y + 22))
    RINSTR_SUB_Y=$((RINSTR_TITLE_Y + 30))
    RDIV2_Y=$((RINSTR_SUB_Y + 44 + 16))
    RFACT_LABEL_Y=$((RDIV2_Y + 14))
    RFACT_TEXT_Y=$((RFACT_LABEL_Y + 24))

    #########################################
    # Rebuild BASE_CHAIN for this video's content
    #########################################
    # Every input is locked to 30fps on entry (see original notes: avoids
    # PTS drift stalling the overlay when the shortest input ends).
    CHAIN="color=c=0x02040C:s=1280x720[canvas];"
    CHAIN+="[0:v]fps=30,scale=${CENTER_W}:${VIDEO_ROW_H}:force_original_aspect_ratio=increase,crop=${CENTER_W}:${VIDEO_ROW_H}[vidfit];"
    CHAIN+="[canvas][vidfit]overlay=${CENTER_X0}:${ROW1_Y}:shortest=1[base];"

    build_labels_chain "$url"
    CHAIN+="$LABELS_CHAIN"

    # ---------------- Cyan broadcast corner brackets on the video ----------------
    local BR_L=26 BR_T=3 BR_M=10
    local VX0=$CENTER_X0
    local VX1=$((CENTER_X0 + CENTER_W))
    local VY0=0
    local VY1=$VIDEO_ROW_H
    CHAIN+="${LABELS_OUT}drawbox=x=$((VX0 + BR_M)):y=$((VY0 + BR_M)):w=${BR_L}:h=${BR_T}:color=${CYAN}@0.95:t=fill[br1];"
    CHAIN+="[br1]drawbox=x=$((VX0 + BR_M)):y=$((VY0 + BR_M)):w=${BR_T}:h=${BR_L}:color=${CYAN}@0.95:t=fill[br2];"
    CHAIN+="[br2]drawbox=x=$((VX1 - BR_M - BR_L)):y=$((VY0 + BR_M)):w=${BR_L}:h=${BR_T}:color=${CYAN}@0.95:t=fill[br3];"
    CHAIN+="[br3]drawbox=x=$((VX1 - BR_M - BR_T)):y=$((VY0 + BR_M)):w=${BR_T}:h=${BR_L}:color=${CYAN}@0.95:t=fill[br4];"
    CHAIN+="[br4]drawbox=x=$((VX0 + BR_M)):y=$((VY1 - BR_M - BR_T)):w=${BR_L}:h=${BR_T}:color=${CYAN}@0.95:t=fill[br5];"
    CHAIN+="[br5]drawbox=x=$((VX0 + BR_M)):y=$((VY1 - BR_M - BR_L)):w=${BR_T}:h=${BR_L}:color=${CYAN}@0.95:t=fill[br6];"
    CHAIN+="[br6]drawbox=x=$((VX1 - BR_M - BR_L)):y=$((VY1 - BR_M - BR_T)):w=${BR_L}:h=${BR_T}:color=${CYAN}@0.95:t=fill[br7];"
    CHAIN+="[br7]drawbox=x=$((VX1 - BR_M - BR_T)):y=$((VY1 - BR_M - BR_L)):w=${BR_T}:h=${BR_L}:color=${CYAN}@0.95:t=fill[br8];"
    # Lower-third caption on the video
    CHAIN+="[br8]drawbox=x=${VX0}:y=$((VY1 - 34)):w=300:h=34:color=${NAVY}@0.7:t=fill[brcap0];"
    CHAIN+="[brcap0]drawbox=x=${VX0}:y=$((VY1 - 34)):w=4:h=34:color=${GOLD}:t=fill[brcap1];"
    CHAIN+="[brcap1]drawtext=fontfile=${FONT}:text='VOYAGER 1  •  ONE LIGHT-DAY':fontcolor=white@0.95:fontsize=13:x=$((VX0 + 16)):y=$((VY1 - 22)):${SHADOW}[brcap2];"
    local prev="brcap2"

    local CARD_PAD=10
    local CARD_X0=$((CENTER_X0 + CARD_PAD))
    local CARD_W=$((CENTER_W - CARD_PAD * 2))

    # ---------------- Row 2: mission-status info block ----------------
    local CM3_Y0=$((ROW2_Y + CARD_PAD))
    local CM3_Y1=$((ROW3_Y - CARD_PAD))
    CHAIN+="[${prev}]drawbox=x=${CARD_X0}:y=${CM3_Y0}:w=${CARD_W}:h=$((CM3_Y1 - CM3_Y0)):color=${CARD}@0.55:t=fill[cm3card];"
    CHAIN+="[cm3card]drawbox=x=${CARD_X0}:y=${CM3_Y0}:w=${CARD_W}:h=$((CM3_Y1 - CM3_Y0)):color=${CYAN}@0.4:t=1[cm3border];"

    local CM3_LABEL_Y=$((CM3_Y0 + 20))
    local CM3_LINE1_Y=$((CM3_LABEL_Y + 30))
    local CM3_LINE2_Y=$((CM3_LINE1_Y + 26))
    local CM3_LINE3_Y=$((CM3_LINE2_Y + 26))
    local CM3_LINE4_Y=$((CM3_LINE3_Y + 26))
    local CM3_LINE5_Y=$((CM3_LINE4_Y + 26))

    CHAIN+="[cm3border]drawbox=x=$((MTEXT_INSET - 2)):y=$((CM3_LABEL_Y - 2)):w=6:h=6:color=${CYAN}:t=fill[cm3z];"
    CHAIN+="[cm3z]drawtext=fontfile=${FONT}:text='MISSION STATUS':fontcolor=${CYAN}@0.95:fontsize=13:x=$((MTEXT_INSET + 14)):y=$((CM3_LABEL_Y - 6))[cm3z2];"
    CHAIN+="[cm3z2]drawbox=x=${MTEXT_INSET}:y=$((CM3_LABEL_Y + 14)):w=$((CARD_W - 40)):h=1:color=${CYAN}@0.3:t=fill[cm3a];"
    CHAIN+="[cm3a]drawtext=fontfile=${FONT}:text='SPACECRAFT':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE1_Y}[cm3b];"
    CHAIN+="[cm3b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_title.txt:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE1_Y}[cm3c];"
    CHAIN+="[cm3c]drawtext=fontfile=${FONT}:text='UTC TIME':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE2_Y}[cm3d];"
    CHAIN+="[cm3d]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=white:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE2_Y}[cm3e];"
    CHAIN+="[cm3e]drawtext=fontfile=${FONT}:text='DISTANCE':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE3_Y}[cm3f];"
    CHAIN+="[cm3f]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_dist_km.txt:reload=1:fontcolor=${CYAN}:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE3_Y}[cm3g];"
    CHAIN+="[cm3g]drawtext=fontfile=${FONT}:text='SIGNAL TIME':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE4_Y}[cm3h];"
    CHAIN+="[cm3h]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_signal.txt:reload=1:fontcolor=${VIOLET}:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE4_Y}[cm3i];"
    CHAIN+="[cm3i]drawtext=fontfile=${FONT}:text='one-way':fontcolor=white@0.45:fontsize=12:x=$((MVALUE_X + 110)):y=$((CM3_LINE4_Y + 1))[cm3j];"
    CHAIN+="[cm3j]drawtext=fontfile=${FONT}:text='LIGHT-DAY IN':fontcolor=white@0.55:fontsize=13:x=${MTEXT_INSET}:y=${CM3_LINE5_Y}[cm3k];"
    CHAIN+="[cm3k]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_countdown.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=${MVALUE_X}:y=${CM3_LINE5_Y}[cm3final];"
    prev="cm3final"

    # ---------------- Center strip: framed thumbnail ----------------
    if [ "$PANEL_IMAGES_AVAILABLE" = true ]; then
        local MID_X0=$((MTEXT_INSET + 400))
        local MID_AVAIL_W=$(((CARD_X0 + CARD_W - 14) - MID_X0))
        local MID_TOP=$((CM3_LABEL_Y + 14 + 14))
        local MID_BOTTOM=$((CM3_Y1 - 16))
        local MID_AVAIL_H=$((MID_BOTTOM - MID_TOP))
        if [ "$MID_AVAIL_W" -ge 90 ] && [ "$MID_AVAIL_H" -ge 90 ]; then
            local MTHUMB=$MID_AVAIL_W
            [ "$MID_AVAIL_H" -lt "$MTHUMB" ] && MTHUMB=$MID_AVAIL_H
            [ "$MTHUMB" -gt 130 ] && MTHUMB=130
            local MTX=$((MID_X0 + (MID_AVAIL_W - MTHUMB) / 2))
            local MTY=$((MID_TOP + (MID_AVAIL_H - MTHUMB) / 2))
            CHAIN+="[${prev}]drawbox=x=$((MTX - 4)):y=$((MTY - 4)):w=$((MTHUMB + 8)):h=$((MTHUMB + 8)):color=${NAVY}@0.8:t=fill[mthumbbg];"
            CHAIN+="[mthumbbg]drawbox=x=$((MTX - 4)):y=$((MTY - 4)):w=$((MTHUMB + 8)):h=$((MTHUMB + 8)):color=${GOLD}@0.65:t=1[mthumbborder];"
            CHAIN+="[3:v]fps=30,scale=${MTHUMB}:${MTHUMB}:force_original_aspect_ratio=increase,crop=${MTHUMB}:${MTHUMB}[mimg];"
            CHAIN+="[mthumbborder][mimg]overlay=x=${MTX}:y=${MTY}:shortest=1[mthumbfinal];"
            prev="mthumbfinal"
        fi
    fi

    # ---------------- Row 3: "DEEP SPACE SIGNAL" visualization ----------------
    # Decorative animated waveform (not real data), drawn as thin
    # contiguous segments; colour blocks alternate cyan / violet.
    local CM4_Y0=$((ROW3_Y + CARD_PAD))
    local CM4_Y1=$((680 - CARD_PAD))
    CHAIN+="[${prev}]drawbox=x=${CARD_X0}:y=${CM4_Y0}:w=${CARD_W}:h=$((CM4_Y1 - CM4_Y0)):color=${CARD}@0.55:t=fill[cm4card];"
    CHAIN+="[cm4card]drawbox=x=${CARD_X0}:y=${CM4_Y0}:w=${CARD_W}:h=$((CM4_Y1 - CM4_Y0)):color=${VIOLET}@0.45:t=1[cm4border];"

    local CM4_LABEL_Y=$((CM4_Y0 + 20))
    local CM4_BASE_Y=$((CM4_Y1 - 14))
    local CM4_LINE_MINH=8
    local CM4_LINE_MAXH=$((CM4_BASE_Y - CM4_LABEL_Y - 20))
    local CM4_LINE_START_X=$((MTEXT_INSET - 4))
    local CM4_LINE_WIDTH=$((CARD_W - 40))
    local CM4_STEP=6
    local CM4_LINE_COUNT=$((CM4_LINE_WIDTH / CM4_STEP))
    local CM4_STROKE_H=4
    local CM4_BLOCK_SIZE=12

    CHAIN+="[cm4border]drawbox=x=$((MTEXT_INSET - 2)):y=$((CM4_LABEL_Y - 2)):w=6:h=6:color=${RED}:t=fill:enable='lt(mod(t\,1.2)\,0.75)'[cm4a];"
    CHAIN+="[cm4a]drawtext=fontfile=${FONT}:text='DEEP SPACE SIGNAL':fontcolor=white@0.8:fontsize=13:x=$((MTEXT_INSET + 14)):y=$((CM4_LABEL_Y - 6))[cm4b];"
    prev="cm4b"
    local di dbx dh_expr dy_expr dnxt dcolor dblock
    for ((di = 0; di < CM4_LINE_COUNT; di++)); do
        dbx=$((CM4_LINE_START_X + di * CM4_STEP))
        dh_expr="clip(58+34*sin(2*PI*t/2.6+${di}*0.12)+18*sin(2*PI*t/1.35+${di}*0.19)\,${CM4_LINE_MINH}\,${CM4_LINE_MAXH})"
        dy_expr="${CM4_BASE_Y}-(${dh_expr})"
        dnxt="cm4ln${di}"
        dblock=$((di / CM4_BLOCK_SIZE))
        if (( dblock % 2 == 0 )); then dcolor="${CYAN}@0.95"; else dcolor="${VIOLET}@0.9"; fi
        CHAIN+="[${prev}]drawbox=x=${dbx}:y='${dy_expr}':w=${CM4_STEP}:h=${CM4_STROKE_H}:color=${dcolor}:t=fill[${dnxt}];"
        prev="$dnxt"
    done
    CHAIN+="[${prev}]drawbox=x=$((MTEXT_INSET - 4)):y=${CM4_BASE_Y}:w=$((CARD_W - 40)):h=1:color=white@0.25:t=fill[cm4base];"

    # ---------------- Left panel: story / headlines ----------------
    CHAIN+="[cm4base]drawbox=x=0:y=0:w=${PANEL_W}:h=720:color=${NAVY}@0.95:t=fill[p1];"
    CHAIN+="[p1]drawbox=x=${PANEL_W}:y=0:w=3:h=720:color=${VIOLET}@0.8:t=fill[p2];"
    CHAIN+="[p2]drawbox=x=0:y=0:w=${PANEL_W}:h=4:color=${CYAN}@0.95:t=fill[p3];"

    CHAIN+="[p3]drawbox=x=27:y=28:w=11:h=11:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p4];"
    CHAIN+="[p4]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=30:x=44:y=19[p5];"
    CHAIN+="[p5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}@0.95:fontsize=13:x=${TEXT_INSET}-text_w+280:y=39[p6];"

    CHAIN+="[p6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=${GOLD}:fontsize=22:x=${TEXT_INSET}:y=95:${SHADOW}[p7];"
    CHAIN+="[p7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=${CYAN}@0.95:fontsize=16:x=${TEXT_INSET}:y=123:${SHADOW}[p8];"
    CHAIN+="[p8]drawbox=x=${TEXT_INSET}:y=153:w=${PANEL_TEXT_W}:h=2:color=${VIOLET}@0.6:t=fill[p9];"

    CHAIN+="[p9]drawbox=x=${TEXT_INSET}:y=171:w=8:h=8:color=${VIOLET}:t=fill[p10];"
    CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${VIOLET}:fontsize=14:x=$((TEXT_INSET + 16)):y=168[p11];"

    local prev="p11"
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local nxt="h${idx}"
        local ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=${TEXT_INSET}:y=${HEADLINE_Y}:alpha='${ALPHA}':${SHADOW}[${nxt}];"
        prev="$nxt"
    done

    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:text='STORY PROGRESS':fontcolor=white@0.4:fontsize=9:x=${TEXT_INSET}:y=$((PROGRESS_Y - 15))[pgcap];"
    CHAIN+="[pgcap]drawbox=x=${TEXT_INSET}:y=${PROGRESS_Y}:w=${PANEL_TEXT_W}:h=2:color=white@0.15:t=fill[pg1];"
    CHAIN+="[pg1]drawbox=x=${TEXT_INSET}:y=${PROGRESS_Y}:w='${PANEL_TEXT_W}*(mod(t\,${SLOT}))/${SLOT}':h=2:color=${CYAN}:t=fill[pg2];"
    prev="pg2"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((TEXT_INSET + i * 17))
        local nxt="db${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=white@0.3:t=fill[${nxt}];"
        prev="$nxt"
    done

    local last=$((N - 1))
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((TEXT_INSET + i * 17))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local ENABLE="between(mod(t\,${CYCLE})\,${start}\,${end})"
        if [ "$i" -eq "$last" ]; then
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[pdotend];"
            prev="pdotend"
        else
            local nxt="da${idx}"
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
            prev="$nxt"
        fi
    done

    # ---------------- Left panel: animated "radio signal" bars ----------------
    # Decorative equalizer (not real data). Bars shade cyan -> violet -> gold.
    local GRAPH_LABEL_Y=$((DOTS_Y + 40))
    local GRAPH_BASE_Y=$((GRAPH_LABEL_Y + 160))
    local BAR_COUNT=14
    local BAR_W=13
    local BAR_GAP=6
    local BAR_MINH=8
    local BAR_MAXH=100

    CHAIN+="[${prev}]drawbox=x=$((TEXT_INSET - 2)):y=$((GRAPH_LABEL_Y - 2)):w=6:h=6:color=${CYAN}:t=fill:enable='lt(mod(t\,1.4)\,0.9)'[sa1];"
    CHAIN+="[sa1]drawtext=fontfile=${FONT}:text='RADIO SIGNAL':fontcolor=white@0.6:fontsize=11:x=$((TEXT_INSET + 14)):y=$((GRAPH_LABEL_Y - 8))[sa2];"
    CHAIN+="[sa2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_band.txt:fontcolor=${GOLD}:fontsize=16:x=${TEXT_INSET}:y=$((GRAPH_LABEL_Y + 10)):${SHADOW}[sa3];"
    prev="sa3"

    local bi bx h_expr y_expr bnxt bcolor
    for ((bi = 0; bi < BAR_COUNT; bi++)); do
        bx=$((TEXT_INSET + bi * (BAR_W + BAR_GAP)))
        h_expr="clip(60+38*sin(2*PI*t/3.1+${bi}*0.55)+18*sin(2*PI*t/1.6+${bi}*0.9)\,${BAR_MINH}\,${BAR_MAXH})"
        y_expr="${GRAPH_BASE_Y}-(${h_expr})"
        bnxt="sabar${bi}"
        if [ "$bi" -lt 5 ]; then bcolor="${CYAN}@0.85"
        elif [ "$bi" -lt 10 ]; then bcolor="${VIOLET}@0.85"
        else bcolor="${GOLD}@0.85"; fi
        CHAIN+="[${prev}]drawbox=x=${bx}:y='${y_expr}':w=${BAR_W}:h='${h_expr}':color=${bcolor}:t=fill[${bnxt}];"
        prev="$bnxt"
    done
    CHAIN+="[${prev}]drawbox=x=${TEXT_INSET}:y=${GRAPH_BASE_Y}:w=${PANEL_TEXT_W}:h=1:color=white@0.25:t=fill[sabase];"
    prev="sabase"

    # ---------------- Right panel: stats + spacecraft + facts ----------------
    CHAIN+="[${prev}]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=720:color=${NAVY}@0.95:t=fill[r1];"
    CHAIN+="[r1]drawbox=x=$((RIGHT_X0 - 3)):y=0:w=3:h=720:color=${VIOLET}@0.8:t=fill[r2];"
    CHAIN+="[r2]drawbox=x=${RIGHT_X0}:y=0:w=${PANEL_W}:h=4:color=${CYAN}@0.95:t=fill[r3];"

    CHAIN+="[r3]drawtext=fontfile=${FONT}:text='Source\: NASA / JPL-Caltech':fontcolor=white@0.85:fontsize=14:x=${RTEXT_INSET}:y=${RSTAT_Y}[r4];"
    CHAIN+="[r4]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=${RTEXT_INSET}:y=$((RSTAT_Y + 20))[r5];"
    CHAIN+="[r5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=${CYAN}@0.9:fontsize=13:x=${RTEXT_INSET}:y=$((RSTAT_Y + 40))[r6];"
    CHAIN+="[r6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=${VIOLET}:fontsize=13:x=${RTEXT_INSET}:y=$((RSTAT_Y + 60))[r7];"

    CHAIN+="[r7]drawbox=x=${RTEXT_INSET}:y=${RDIV1_Y}:w=${PANEL_TEXT_W}:h=2:color=${CYAN}@0.3:t=fill[r8];"

    CHAIN+="[r8]drawbox=x=${RTEXT_INSET}:y=${RINSTR_LABEL_Y}:w=8:h=8:color=${GOLD}:t=fill[r9];"
    CHAIN+="[r9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_label.txt:fontcolor=${GOLD}:fontsize=14:x=$((RTEXT_INSET + 16)):y=$((RINSTR_LABEL_Y - 3))[r10];"
    CHAIN+="[r10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_title.txt:fontcolor=white:fontsize=20:x=${RTEXT_INSET}:y=${RINSTR_TITLE_Y}:${SHADOW}[r11];"
    CHAIN+="[r11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/instr_sub.wrapped.txt:fontcolor=${CYAN}@0.85:fontsize=14:line_spacing=6:x=${RTEXT_INSET}:y=${RINSTR_SUB_Y}[r12];"

    CHAIN+="[r12]drawbox=x=${RTEXT_INSET}:y=${RDIV2_Y}:w=${PANEL_TEXT_W}:h=2:color=${VIOLET}@0.6:t=fill[r13];"
    CHAIN+="[r13]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${VIOLET}:fontsize=12:x=${RTEXT_INSET}:y=${RFACT_LABEL_Y}[r14];"
    prev="r14"
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        local start=$((i * FACT_SLOT))
        local end=$((start + FACT_SLOT))
        local nxt="f${idx}"
        local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${FACT_CYCLE})-${start}\,0.6)\,(mod(t\,${FACT_CYCLE})-${start})/0.6\,if(gt(mod(t\,${FACT_CYCLE})-${start}\,${FACT_SLOT}-0.6)\,(${end}-mod(t\,${FACT_CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=white@0.92:fontsize=${FACT_FONTSIZE}:line_spacing=${FACT_LINE_SPACING}:x=${RTEXT_INSET}:y=${RFACT_TEXT_Y}:alpha='${FALPHA}'[${nxt}];"
        prev="$nxt"
    done

    # ---------------- Right panel: live telemetry + countdown ----------------
    local RREAD_DIV_Y=$((RFACT_TEXT_Y + MAX_FACT_LINES * FACT_LINE_H + 16))
    local RREAD_LABEL_Y=$((RREAD_DIV_Y + 14))
    local RREAD_LINE1_Y=$((RREAD_LABEL_Y + 22))
    local RREAD_LINE2_Y=$((RREAD_LINE1_Y + 20))
    local RREAD_LINE3_Y=$((RREAD_LINE2_Y + 20))
    local RREAD_LINE4_Y=$((RREAD_LINE3_Y + 20))
    local RGRAPH_LABEL_Y=$((RREAD_LINE4_Y + 30))

    CHAIN+="[${prev}]drawbox=x=${RTEXT_INSET}:y=${RREAD_DIV_Y}:w=${PANEL_TEXT_W}:h=2:color=${CYAN}@0.3:t=fill[rr0];"
    CHAIN+="[rr0]drawtext=fontfile=${FONT}:text='LIVE TELEMETRY (EST.)':fontcolor=${CYAN}@0.95:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LABEL_Y}[rr0b];"
    CHAIN+="[rr0b]drawtext=fontfile=${FONT}:text='DISTANCE':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE1_Y}[rr0c];"
    CHAIN+="[rr0c]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_dist_bn.txt:reload=1:fontcolor=${CYAN}:fontsize=14:x=$((RTEXT_INSET + 90)):y=${RREAD_LINE1_Y}[rr1];"
    CHAIN+="[rr1]drawtext=fontfile=${FONT}:text='SPEED':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE2_Y}[rr1b];"
    CHAIN+="[rr1b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_speed.txt:reload=1:fontcolor=white:fontsize=14:x=$((RTEXT_INSET + 90)):y=${RREAD_LINE2_Y}[rr2];"
    CHAIN+="[rr2]drawtext=fontfile=${FONT}:text='SIGNAL':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE3_Y}[rr2b];"
    CHAIN+="[rr2b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_signal.txt:reload=1:fontcolor=${VIOLET}:fontsize=14:x=$((RTEXT_INSET + 90)):y=${RREAD_LINE3_Y}[rr2c];"
    CHAIN+="[rr2c]drawtext=fontfile=${FONT}:text='MISSION AGE':fontcolor=white@0.55:fontsize=12:x=${RTEXT_INSET}:y=${RREAD_LINE4_Y}[rr2d];"
    CHAIN+="[rr2d]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_met.txt:reload=1:fontcolor=white:fontsize=14:x=$((RTEXT_INSET + 90)):y=${RREAD_LINE4_Y}[rr3];"
    prev="rr3"

    CHAIN+="[${prev}]drawbox=x=$((RTEXT_INSET - 2)):y=$((RGRAPH_LABEL_Y - 2)):w=6:h=6:color=${RED}:t=fill:enable='lt(mod(t\,1.2)\,0.75)'[rg1];"
    CHAIN+="[rg1]drawtext=fontfile=${FONT}:text='ONE LIGHT-DAY IN':fontcolor=white@0.6:fontsize=11:x=$((RTEXT_INSET + 14)):y=$((RGRAPH_LABEL_Y - 8))[rg1b];"
    CHAIN+="[rg1b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_countdown.txt:reload=1:fontcolor=${GOLD}:fontsize=16:x=${RTEXT_INSET}:y=$((RGRAPH_LABEL_Y + 10)):${SHADOW}[rg2];"
    prev="rg2"

    # ---------------- Right panel: light-day progress pie ----------------
    # Wedge = fraction of one light-day covered, computed when this
    # video starts (so it is real, not animated). Cyan = covered,
    # dark indigo = remaining. geq source overlay MUST use shortest=1.
    local PIE_FRAC
    PIE_FRAC="$(voyager_fraction)"
    local PIE_LABEL_Y=$((RGRAPH_LABEL_Y + 40))
    local PIE_TOP=$((PIE_LABEL_Y + 18))
    local PIE_AVAIL_H=$((700 - PIE_TOP))
    local PIE_SIZE=$PIE_AVAIL_H
    [ "$PIE_SIZE" -gt "$PANEL_TEXT_W" ] && PIE_SIZE=$PANEL_TEXT_W
    [ "$PIE_SIZE" -gt 140 ] && PIE_SIZE=140
    local PIE_CX=$((PIE_SIZE / 2))
    local PIE_CY=$((PIE_SIZE / 2))
    local PIE_R=$((PIE_SIZE / 2 - 4))
    local PIE_X=$((RTEXT_INSET + (PANEL_TEXT_W - PIE_SIZE) / 2))
    local PIE_Y=$PIE_TOP

    local PIE_DIST="hypot(X-${PIE_CX}\,Y-${PIE_CY})"
    local PIE_THETA="mod(atan2(Y-${PIE_CY}\,X-${PIE_CX})+PI/2+2*PI\,2*PI)"
    local PIE_FILL_ANGLE="(2*PI*${PIE_FRAC})"
    local PIE_R_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,if(lte(${PIE_THETA}\,${PIE_FILL_ANGLE})\,${CYAN_R}\,${PIE_REST_R})\,0)"
    local PIE_G_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,if(lte(${PIE_THETA}\,${PIE_FILL_ANGLE})\,${CYAN_G}\,${PIE_REST_G})\,0)"
    local PIE_B_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,if(lte(${PIE_THETA}\,${PIE_FILL_ANGLE})\,${CYAN_B}\,${PIE_REST_B})\,0)"
    local PIE_A_EXPR="if(lte(${PIE_DIST}\,${PIE_R})\,255\,0)"

    CHAIN+="[${prev}]drawbox=x=$((RTEXT_INSET - 2)):y=$((PIE_LABEL_Y - 2)):w=6:h=6:color=${GOLD}:t=fill[rgp1];"
    CHAIN+="[rgp1]drawtext=fontfile=${FONT}:text='LIGHT-DAY PROGRESS':fontcolor=white@0.6:fontsize=11:x=$((RTEXT_INSET + 14)):y=$((PIE_LABEL_Y - 8))[rgp2];"
    CHAIN+="color=c=black@0:s=${PIE_SIZE}x${PIE_SIZE}[pie_src];"
    CHAIN+="[pie_src]format=rgba,geq=r='${PIE_R_EXPR}':g='${PIE_G_EXPR}':b='${PIE_B_EXPR}':a='${PIE_A_EXPR}'[pie_img];"
    CHAIN+="[rgp2][pie_img]overlay=x=${PIE_X}:y=${PIE_Y}:shortest=1[rgp3];"
    CHAIN+="[rgp3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/v_pct.txt:reload=1:fontcolor=white:fontsize=15:x=$((PIE_X + PIE_SIZE / 2))-text_w/2:y=$((PIE_Y + PIE_SIZE / 2 - 8)):box=1:boxcolor=${NAVY}@0.7:boxborderw=4:${SHADOW}[rgp4];"
    CHAIN+="[rgp4]drawbox=x=${RTEXT_INSET}:y=$((PIE_Y + PIE_SIZE + 15)):w=${PANEL_TEXT_W}:h=1:color=white@0.25:t=fill[rgbase];"
    prev="rgbase"

    BASE_CHAIN="$CHAIN"
    FACT_END="$prev"
}

#############################################
# build_final_filter: appends the CTA / next-video countdown /
# ticker / watermark section onto BASE_CHAIN.
#############################################
build_final_filter() {
    local total_duration="$1"
    local tail="$BASE_CHAIN"

    local CTA_CYCLE=240
    local CTA_SHOW=8
    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.6)\,mod(t\,${CTA_CYCLE})/0.6\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.6)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    local COUNTDOWN_ENABLE="not(${CTA_ENABLE})"

    local CTA_W=460
    local CTA_X=$((CENTER_X0 + (CENTER_W - CTA_W) / 2))
    local CTA_Y=640

    tail+="[${FACT_END}]drawbox=x=${CTA_X}:y=${CTA_Y}:w=${CTA_W}:h=43:color=${NAVY}@0.85:t=fill[cta_bg];"
    tail+="[cta_bg]drawbox=x=${CTA_X}:y=${CTA_Y}:w=${CTA_W}:h=43:color=${GOLD}@0.55:t=1[cta_frame];"
    tail+="[cta_frame]drawbox=x=${CTA_X}:y=${CTA_Y}:w=4:h=43:color=${GOLD}:t=fill[cta_bar];"
    tail+="[cta_bar]drawbox=x=$((CTA_X + 22)):y=$((CTA_Y + 16)):w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    tail+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=${GOLD}:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):alpha='${CTA_ALPHA}'[cta_sub];"

    if [[ "$total_duration" =~ ^[0-9]+$ ]] && [ "$total_duration" -gt 0 ]; then
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Next view in %{eif\:max(${total_duration}-t\,0)\:d}s':fontcolor=white:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):enable='${COUNTDOWN_ENABLE}'[cta_final];"
    else
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Coming up next...':fontcolor=white@0.85:fontsize=18:x=$((CTA_X + 40)):y=$((CTA_Y + 13)):enable='${COUNTDOWN_ENABLE}'[cta_final];"
    fi

    # Bottom ticker spans the full width.
    tail+="[cta_final]drawbox=x=0:y=680:w=1280:h=40:color=${NAVY}@0.92:t=fill[tk1];"
    tail+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${CYAN}@0.9:t=fill[tk2];"
    tail+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    tail+="[tk3]drawbox=x=0:y=680:w=120:h=40:color=${NAVY}:t=fill[tk4];"
    tail+="[tk4]drawbox=x=0:y=682:w=113:h=38:color=${GOLD}:t=fill[tk5];"
    tail+="[tk5]drawtext=fontfile=${FONT}:text='LIVE NOW':fontcolor=black:fontsize=15:x=13:y=695[tk6];"

    tail+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=${GOLD}@0.7:fontsize=14:borderw=1.5:bordercolor=black@0.7:x=(w-text_w)/2:y=657[final]"

    echo "$tail"
}

#############################################
# is_image_url
#############################################
is_image_url() {
    local u="${1%%\?*}"
    local ext="${u##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        jpg|jpeg|png|gif|bmp|webp) return 0 ;;
        *) return 1 ;;
    esac
}

#############################################
# get_image_local_path
#############################################
get_image_local_path() {
    local url="$1"
    local base="${url##*/}"
    base="${base%%\?*}"
    local dest="img_cache_${base}"
    if [ ! -s "$dest" ]; then
        echo "Downloading image slide: $base" >&2
        if ! curl -sL --fail -o "$dest" "$url"; then
            rm -f "$dest"
            return 1
        fi
    fi
    echo "$dest"
    return 0
}

#############################################
# Stream one video with automatic retry on failure/crash.
#############################################
run_video() {
    local url="$1"
    local attempt=1

    local is_image=false
    local stream_source="$url"
    if is_image_url "$url"; then
        is_image=true
        local local_img
        if ! local_img=$(get_image_local_path "$url"); then
            echo "WARNING: failed to download image slide '$url' — skipping it."
            return 1
        fi
        stream_source="$local_img"
        echo "Image slide: $url -> $stream_source"
    fi

    prepare_video_content "$url"

    local duration
    if [ "$is_image" = true ]; then
        duration="$IMAGE_SLIDE_SECONDS"
        echo "Static image slide — showing for ${duration}s, locked to 30fps."
    else
        duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url" 2>/dev/null || echo "")
        duration=${duration%.*}
        [[ "$duration" =~ ^[0-9]+$ ]] || duration=""
        if [ -n "$duration" ]; then
            echo "Probed duration: ${duration}s"
        else
            echo "Could not probe duration — countdown will show generic filler text."
        fi
    fi

    local filter
    filter=$(build_final_filter "$duration")

    local AUDIO_INPUT_ARGS=()
    local AUDIO_MAP="2:a"
    if [ "$AUDIO_AVAILABLE" = true ]; then
        local this_audio="${AUDIO_LOCAL_FILES[$((AUDIO_COUNTER % NUM_AUDIO))]}"
        AUDIO_COUNTER=$((AUDIO_COUNTER + 1))
        echo "Background audio for this video: $this_audio"
        AUDIO_INPUT_ARGS=(-stream_loop -1 -i "$this_audio")
    else
        AUDIO_INPUT_ARGS=(-f lavfi -i "anullsrc=r=48000:cl=stereo")
    fi

    local PANEL_IMG_INPUT_ARGS=()
    if [ "$PANEL_IMAGES_AVAILABLE" = true ]; then
        PANEL_IMG_INPUT_ARGS=(-loop 1 -framerate 30 -i "$MID_PANEL_IMG")
    fi

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        local MAIN_INPUT_ARGS=()
        local EXTRA_OUTPUT_ARGS=()
        if [ "$is_image" = true ]; then
            MAIN_INPUT_ARGS=(-loop 1 -framerate 30 -i "$stream_source")
            EXTRA_OUTPUT_ARGS=(-t "$duration")
        else
            MAIN_INPUT_ARGS=(-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 -re -i "$stream_source")
        fi

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        "${MAIN_INPUT_ARGS[@]}" \
        -loop 1 -framerate 30 -i "$DOT_MARKER" \
        "${AUDIO_INPUT_ARGS[@]}" \
        "${PANEL_IMG_INPUT_ARGS[@]}" \
        -filter_complex "$filter" \
        -map "[final]" \
        -map "$AUDIO_MAP" \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
        -pix_fmt yuv420p \
        -b:v 3000k \
        -maxrate 3000k \
        -bufsize 6000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        "${EXTRA_OUTPUT_ARGS[@]}" \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "Video finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this video. Moving on."
        fi
    done
    return 1
}

#############################################
# Stream loop
#############################################
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
    u="${u#"${u%%[![:space:]]*}"}"
    u="${u%"${u##*[![:space:]]}"}"
    [ -n "$u" ] && URLS+=("$u")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi

if [ "$NUM_URLS" -gt 1 ]; then
    mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | shuf)
    echo "Shuffled playback order for this run:"
    for u in "${URLS[@]}"; do
        echo "  - $u"
    done
fi

while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"

        run_video "$url" || true

        echo "Loading next video..."
        echo ""
    done
done
