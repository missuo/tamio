#!/bin/bash
# Render the light, code-drawn social card at 1200×630. All assets stay local.
# Requires Python 3, Google Chrome (or CHROME_BIN), and ImageMagick.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
site="$(dirname "$here")/public"
chrome="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

command -v python3 >/dev/null || { echo "Python 3 is required." >&2; exit 1; }
command -v magick >/dev/null || { echo "ImageMagick is required." >&2; exit 1; }
[[ -x "$chrome" ]] || { echo "Set CHROME_BIN to your Chrome executable." >&2; exit 1; }

work="$(mktemp -d)"
server=""
cleanup() {
  if [[ -n "$server" ]]; then
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$here/card.html" "$work/card.html"
cp "$site/icon-256.png" "$site/server-garden.svg" "$work/"

# Let the OS choose a free port, then publish it only once the server is bound.
python3 - "$work" <<'PY' >/dev/null 2>&1 &
import functools
import http.server
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
    (directory / "port").write_text(str(server.server_port))
    server.serve_forever()
PY
server=$!
for ((attempt = 0; attempt < 50; attempt++)); do
  [[ -s "$work/port" ]] && break
  kill -0 "$server" 2>/dev/null || { echo "Preview server failed to start." >&2; exit 1; }
  sleep 0.1
done
[[ -s "$work/port" ]] || { echo "Preview server timed out." >&2; exit 1; }
port="$(cat "$work/port")"

# A disposable profile prevents sharing state with an existing Chrome session.
"$chrome" --headless=new --disable-gpu --hide-scrollbars \
    --user-data-dir="$work/chrome-profile" --no-first-run --no-default-browser-check \
    --force-device-scale-factor=2 --window-size=1200,630 \
    --virtual-time-budget=2000 --screenshot="$work/og@2x.png" \
    "http://127.0.0.1:$port/card.html" >"$work/chrome.log" 2>&1 || {
      cat "$work/chrome.log" >&2
      exit 1
    }
magick "$work/og@2x.png" -filter Lanczos -resize 1200x630 -strip \
    -define png:compression-level=9 "$site/og.png"
echo "wrote $site/og.png"
