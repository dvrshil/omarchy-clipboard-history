#!/bin/bash

# Actions for the dvrshil.clipboard overlay. The shell runs this with a fixed
# argv (never through a shell string), so every value arrives as one literal
# argument. Nothing here evaluates clipboard content.
#
#   actions.sh copy-index  <history-index> [--paste]
#   actions.sh copy-file   <text-file>     [--paste]   (pinned/edited text)
#   actions.sh copy-image  <mime> <path>   [--paste]
#   actions.sh ocr         <image-path>
#   actions.sh qr          <image-path>
#   actions.sh open-url    <http(s)/ftp/mailto url>
#   actions.sh open-path   <absolute path>
#   actions.sh reveal      <absolute path>
#   actions.sh share       <absolute path>...
#   actions.sh share-text  <text-file>
#   actions.sh set-shortcut <hyprland chord>

set -o pipefail

HISTORY="$HOME/.local/state/omarchy/clipboard-history.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/dvrshil-clipboard"
BINDINGS="$HOME/.config/hypr/bindings.lua"
mkdir -p "$STATE_DIR"

notify() {
  notify-send -a "Clipboard" -i edit-paste "$@" 2>/dev/null || true
}

paste_now() {
  sleep 0.15
  wtype -M shift -k Insert -m shift 2>/dev/null || true
}

abs_path() {
  [[ ${1:-} == /* && -e $1 ]]
}

cmd=${1:-}
shift || true

case "$cmd" in
copy-text)
  # Text arrives on stdin, so it never touches argv or a shell string. Spool
  # it, then finish detached so the clipboard owner outlives the shell's
  # process handle.
  tmp=$(mktemp --tmpdir="$STATE_DIR" text.XXXXXX) || exit 1
  head -c 20000000 >"$tmp"
  [[ -s $tmp ]] || { rm -f -- "$tmp"; exit 1; }
  setsid -f "$0" copy-spooled "$tmp" "${1:-}" </dev/null >/dev/null 2>&1
  ;;

copy-spooled)
  file=${1:-}
  [[ $file == "$STATE_DIR"/text.* && -r $file ]] || exit 1
  wl-copy --type text/plain <"$file"
  rm -f -- "$file"
  [[ ${2:-} == --paste ]] && paste_now
  ;;

copy-image)
  mime=${1:-}
  path=${2:-}
  [[ $mime =~ ^image/[A-Za-z0-9.+-]+$ ]] || exit 1
  abs_path "$path" || { notify "Image is gone" "The file for this entry no longer exists."; exit 1; }
  wl-copy --type "$mime" <"$path"
  [[ ${3:-} == --paste ]] && paste_now
  ;;

ocr)
  path=${1:-}
  abs_path "$path" || exit 1
  command -v tesseract >/dev/null || { notify "OCR unavailable" "Install tesseract to read text from images."; exit 1; }
  text=$(timeout 30s tesseract "$path" - 2>/dev/null | sed -e 's/[[:space:]]*$//' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
  if [[ -z ${text//[[:space:]]/} ]]; then
    notify "No text found" "Couldn't recognise any text in that image."
    exit 1
  fi
  printf '%s' "$text" | wl-copy --type text/plain
  notify "Copied text from image" "${text:0:200}"
  ;;

qr)
  path=${1:-}
  abs_path "$path" || exit 1
  command -v zbarimg >/dev/null || { notify "QR unavailable" "Install zbar to read QR codes."; exit 1; }
  text=$(timeout 15s zbarimg --quiet --raw "$path" 2>/dev/null)
  if [[ -z $text ]]; then
    notify "No QR code found" "Couldn't find a QR code in that image."
    exit 1
  fi
  printf '%s' "$text" | wl-copy --type text/plain
  notify "Copied QR code contents" "${text:0:200}"
  ;;

open-url)
  url=${1:-}
  [[ $url =~ ^(https?|ftp)://[^[:space:]]+$ || $url =~ ^mailto:[^[:space:]]+$ ]] || exit 1
  if [[ $url == mailto:* ]]; then
    exec xdg-open "$url"
  fi
  exec omarchy-launch-browser "$url"
  ;;

open-path)
  path=${1:-}
  abs_path "$path" || exit 1
  exec xdg-open "$path"
  ;;

reveal)
  path=${1:-}
  abs_path "$path" || exit 1
  [[ -d $path ]] || path=$(dirname -- "$path")
  exec xdg-open "$path"
  ;;

share)
  for p in "$@"; do abs_path "$p" || exit 1; done
  (($# > 0)) || exit 1
  exec omarchy-menu-share file "$@"
  ;;

share-text)
  out=$(mktemp --suffix=.txt) || exit 1
  head -c 20000000 >"$out"
  [[ -s $out ]] || exit 1
  exec omarchy-menu-share file "$out"
  ;;

set-shortcut)
  chord=${1:-}
  # A Hyprland chord: modifiers and a key joined by " + ", nothing else.
  [[ $chord =~ ^[A-Za-z0-9_]+([[:space:]]*\+[[:space:]]*[A-Za-z0-9_]+)*$ ]] || { notify "Invalid shortcut" "$chord"; exit 1; }
  [[ -f $BINDINGS ]] || touch "$BINDINGS"

  begin="-- >>> dvrshil.clipboard shortcut (managed by the plugin's Shortcut setting)"
  end="-- <<< dvrshil.clipboard shortcut"
  block="$begin
o.bind(\"$chord\", \"Clipboard history\", { panel = \"dvrshil.clipboard\" })
$end"

  # Several plugin instances can start at once (hot reload, overlay + bar),
  # so serialise, and always leave exactly one managed block.
  exec 9>"$STATE_DIR/set-shortcut.lock"
  flock -w 10 9 || exit 1

  existing=$(awk -v b="$begin" -v e="$end" '$0 == b { on = 1 } on { print } on && $0 == e { on = 0 }' "$BINDINGS")
  [[ $existing == "$block" ]] && exit 0

  cp -- "$BINDINGS" "$BINDINGS.bak.$(date +%s)"
  tmp=$(mktemp)
  # Drop every managed block (and the blank line before it), then append one.
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip = 1; pending = ""; next }
    skip { if ($0 == e) skip = 0; next }
    /^$/ { pending = pending "\n"; next }
    { printf "%s", pending; pending = ""; print }
  ' "$BINDINGS" >"$tmp"
  printf '\n%s\n' "$block" >>"$tmp"
  cat "$tmp" >"$BINDINGS"
  rm -f -- "$tmp"

  hyprctl reload >/dev/null 2>&1 || true
  errors=$(hyprctl configerrors 2>/dev/null | grep -v '^$' || true)
  if [[ -n $errors && $errors != *"no errors"* ]]; then
    notify "Shortcut may not have applied" "$errors"
  else
    notify "Clipboard history shortcut" "$chord"
  fi
  ;;

*)
  echo "usage: actions.sh <command> ..." >&2
  exit 1
  ;;
esac
