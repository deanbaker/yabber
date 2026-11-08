#!/usr/bin/env bash
# Build, install, run and collect logs for the background-transcription probe.
#   scripts/probe.sh team <TEAM_ID>      write Prototype/BackgroundProbe/Config/Local.xcconfig
#   scripts/probe.sh build               generate project + signed device build
#   scripts/probe.sh install             install on the connected iPhone
#   scripts/probe.sh run ANE|CPU|GPU [1|6]   launch and start a run (background plan in minutes)
#   scripts/probe.sh pull                copy the app's logs to results/
# Set DEVICE=<udid or name> if more than one iPhone is connected.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/Prototype/BackgroundProbe"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Debug-iphoneos/BackgroundProbe.app"

bundle_id() {
  local local_id
  local_id=$(sed -n 's/^PROBE_BUNDLE_ID *= *//p' "$PROJ/Config/Local.xcconfig" 2>/dev/null || true)
  [[ -n "$local_id" ]] && echo "$local_id" || sed -n 's/^PROBE_BUNDLE_ID *= *//p' "$PROJ/Config/Base.xcconfig"
}

device() {
  if [[ -n "${DEVICE:-}" ]]; then echo "$DEVICE"; return; fi
  local json; json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null
  /usr/bin/python3 -I - "$json" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
phys = [d for d in devs if d.get("hardwareProperties", {}).get("reality") == "physical"
        and d.get("hardwareProperties", {}).get("platform") == "iOS"]
if not phys:
    sys.exit("No physical iPhone found. Connect it by USB and unlock it.")
print(phys[0]["hardwareProperties"]["udid"])
PY
  rm -f "$json"
}

case "${1:-}" in install|run|pull) dev=$(device) ;; esac

case "${1:-}" in
  team)
    printf 'DEVELOPMENT_TEAM = %s\n' "${2:?team id}" > "$PROJ/Config/Local.xcconfig"
    [[ -n "${3:-}" ]] && printf 'PROBE_BUNDLE_ID = %s\n' "$3" >> "$PROJ/Config/Local.xcconfig"
    cat "$PROJ/Config/Local.xcconfig" ;;
  build)
    (cd "$PROJ" && xcodegen generate --quiet)
    xcodebuild -project "$PROJ/BackgroundProbe.xcodeproj" -scheme BackgroundProbe \
      -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" ;;
  install)
    xcrun devicectl device install app --device "$dev" "$APP" ;;
  run)
    mode="${2:-ANE}"; minutes="${3:-6}"
    [[ "$mode" == GPU ]] && mode="GPU (control)"
    xcrun devicectl device process launch --device "$dev" --terminate-existing \
      "$(bundle_id)" -- -autorun -mode "$mode" -plan "$minutes min" ;;
  pull)
    mkdir -p "$ROOT/results"
    xcrun devicectl device copy from --device "$dev" --domain-type appDataContainer \
      --domain-identifier "$(bundle_id)" --source Documents --destination "$ROOT/results"
    ls -lt "$ROOT/results" | head ;;
  *)
    sed -n 2,9p "$0"; exit 1 ;;
esac
