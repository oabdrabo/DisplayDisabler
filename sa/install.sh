#!/bin/sh
# Installs DisplayDisabler's scripting addition to /Library/DisplayDisabler,
# grants passwordless re-loading via sudoers, and injects it into Dock.
# Run as root (via admin prompt on first install). Args: <resources_sa_dir> <username>
set -e

SRC="$1"
USERNAME="$2"
DD=/Library/DisplayDisabler
LOADER="$DD/loader"

# clean up any prior location
rm -rf /Library/ScriptingAdditions/dd.osax

mkdir -p "$DD"
cp "$SRC/loader"  "$DD/loader"
cp "$SRC/payload" "$DD/payload"
chown -R root:wheel "$DD"
chmod -R 0755 "$DD"

echo "$USERNAME ALL=(root) NOPASSWD: $LOADER" > /private/etc/sudoers.d/displaydisabler
chmod 0440 /private/etc/sudoers.d/displaydisabler

"$LOADER"
