#!/bin/bash
set -e
cd "$(dirname "$0")/.."
DD="com.local.DisplayDeck"
TMP=$(mktemp -d)

echo "building capture tools…"
clang -fobjc-arc -O2 -framework Cocoa -framework ApplicationServices tools/ddshot.m  -o "$TMP/ddshot"
clang -fobjc-arc          -framework Cocoa                              tools/ddcrop.m  -o "$TMP/ddcrop"

relaunch(){ osascript -e 'quit app "DisplayDeck"' 2>/dev/null || true; sleep 2; open -a DisplayDeck; sleep 3; }

echo "capturing main menu + submenus…"
relaunch
"$TMP/ddshot" "$TMP/menu.png"
"$TMP/ddshot" "$TMP/forcehidpi.png" "Force HiDPI"
"$TMP/ddshot" "$TMP/windowsnap.png" "Snap Window"
"$TMP/ddshot" "$TMP/arrange.png"    "Arrange Windows"
"$TMP/ddshot" "$TMP/keepawake.png"  "Keep Awake"
"$TMP/ddshot" "$TMP/resolution.png" "Resolution"
"$TMP/ddshot" "$TMP/settings.png"   "Settings"

echo "cropping Brightness/Warmth + Transparency sections from the menu…"
"$TMP/ddcrop" "$TMP/menu.png" 0 64  502 150 "$TMP/brightness-warmth.png"
"$TMP/ddcrop" "$TMP/menu.png" 0 566 508 320 "$TMP/transparency.png"

echo "capturing Remote Access with the relay IP masked…"
REAL=$(defaults read "$DD" RemoteRelayHost 2>/dev/null || echo "")
defaults write "$DD" RemoteRelayHost "relay.example.com"
relaunch
"$TMP/ddshot" "$TMP/remote.png" "Remote Access"
[ -n "$REAL" ] && defaults write "$DD" RemoteRelayHost "$REAL" || defaults delete "$DD" RemoteRelayHost 2>/dev/null || true
relaunch

echo "installing into assets/ and docs/assets/…"
for d in assets/screenshots docs/assets/screenshots; do
  cp "$TMP"/{menu,forcehidpi,windowsnap,arrange,keepawake,resolution,settings,remote,brightness-warmth,transparency}.png "$d/"
done
rm -rf "$TMP"
echo "done — review with: git diff --stat assets docs/assets"
