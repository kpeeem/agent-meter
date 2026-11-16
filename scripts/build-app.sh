#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
mkdir -p .build/manifest-cache .build/cache build
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$root/.build/manifest-cache}"
swift_options=(--configuration release -debug-info-format none --cache-path "$root/.build/cache")
if [[ "${AGENT_METER_SWIFTPM_DISABLE_SANDBOX:-0}" == 1 ]]; then
    swift_options+=(--disable-sandbox)
fi
swift build "${swift_options[@]}"
bin="$(swift build "${swift_options[@]}" --show-bin-path)"

stage="$(mktemp -d "$root/build/.package.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/Agent Meter.app"
mkdir -p "$app/Contents/"{MacOS,Helpers,Resources}

cp Packaging/Info.plist "$app/Contents/Info.plist"
cp -R Packaging/Fonts Packaging/Licenses Packaging/ProviderIcons Packaging/TerminalFocus "$app/Contents/Resources/"
install -m 0755 "$bin/AgentMeter" "$app/Contents/MacOS/AgentMeter"
install -m 0755 "$bin/AgentMeterStatus" "$app/Contents/Helpers/AgentMeterStatus"
install -m 0755 "$bin/AgentMeterHook" "$app/Contents/Helpers/AgentMeterHook"
install -m 0755 "$bin/AgentMeterRefresh" "$app/Contents/Helpers/AgentMeterRefresh"

swift -module-cache-path "$root/.build/manifest-cache" scripts/make-icon.swift "$app/Contents/Resources/AppIcon.icns"

identity="${AGENT_METER_CODESIGN_IDENTITY:-}"
if [[ -z "$identity" ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"Agent Meter Local"'; then
    identity="Agent Meter Local"
fi
identity="${identity:--}"
codesign --force --sign "$identity" --options runtime "$app/Contents/Helpers/AgentMeterStatus"
codesign --force --sign "$identity" --options runtime "$app/Contents/Helpers/AgentMeterHook"
codesign --force --sign "$identity" --options runtime "$app/Contents/Helpers/AgentMeterRefresh"
codesign --force --sign "$identity" --options runtime --entitlements Packaging/AgentMeter.entitlements "$app"
codesign --verify --deep --strict "$app"

output="$root/build/Agent Meter.app"
if [[ -e "$output" ]]; then
    mv "$output" "$stage/previous.app"
fi
if ! mv "$app" "$output"; then
    if [[ -d "$stage/previous.app" ]]; then mv "$stage/previous.app" "$output"; fi
    exit 1
fi
printf '%s\n' "$output"
