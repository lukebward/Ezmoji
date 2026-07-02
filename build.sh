#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Ezmoji.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/Ezmoji" Sources/main.swift
cp Resources/emoji.json "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"

# Prefer a real dev identity: TCC then tracks the app across rebuilds, so the
# Accessibility grant survives. Ad-hoc fallback needs a re-grant per rebuild.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (Accessibility must be re-granted after each rebuild)"
fi

echo "Built $APP"
echo "Run:  open $APP"
