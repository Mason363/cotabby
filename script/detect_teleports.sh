#!/usr/bin/env bash
set -euo pipefail

# Counts ghost-text "teleports" from the overlay-present telemetry stream.
#
# A teleport is two consecutive show records for the SAME suggestion in the SAME focus session
# whose panel frame jumped further than typing could explain, or whose render mode flipped
# (inline <-> mirror), which visually relocates the ghost from the caret to the field edge.
# Thresholds: |dy| > max(8, 0.5 * line_height), |dx| > 60pt, or a mode flip.
#
# Usage: script/detect_teleports.sh [path-to-cotabby.jsonl] [host-bundle-id-filter]
# Defaults to the dev-identity log. Requires the app to run with -cotabby-debug.

LOG="${1:-$HOME/Library/Logs/Cotabby Dev/cotabby.jsonl}"
BUNDLE_FILTER="${2:-}"

jq -c --arg bundle "$BUNDLE_FILTER" '
  select(.stage == "overlay-present" and (.event == "inline_show" or .event == "mirror_show"))
  | select($bundle == "" or .host_bundle_id == $bundle)
  | {t: .timestamp, app: .host_bundle_id, seq: .focus_change_sequence, h: .text_hash,
     x: (.panel_x | tonumber), y: (.panel_y | tonumber), m: .render_mode,
     lh: ((.line_height // "16") | tonumber)}' "$LOG" \
| jq -s '
  def abs: if . < 0 then -. else . end;
  [range(1; length) as $i
   | select(.[$i].seq == .[$i-1].seq and .[$i].h == .[$i-1].h)
   | {from: .[$i-1], to: .[$i],
      dx: (.[$i].x - .[$i-1].x), dy: (.[$i].y - .[$i-1].y)}
   | select((.dy | abs) > ([8, .to.lh * 0.5] | max)
       or (.dx | abs) > 60
       or .from.m != .to.m)]
  | {teleports: length,
     by_app: (group_by(.to.app) | map({app: .[0].to.app, count: length})),
     cases: (.[0:20])}'
