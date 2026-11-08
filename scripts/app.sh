#!/usr/bin/env bash
# Build and run the WisprFree app + keyboard on the connected iPhone.
#   scripts/app.sh team <TEAM_ID>   write App/Config/Local.xcconfig
#   scripts/app.sh build            generate project + signed build for the connected iPhone
#   scripts/app.sh install          install on the iPhone
#   scripts/app.sh launch           launch the app (no debugger, so background behaviour is real)
#   scripts/app.sh log [N]          print the last N lines of the shared app/keyboard debug log
# Set DEVICE=<udid or name> if more than one iPhone is connected.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="$ROOT/App"
DERIVED="$ROOT/build/AppDerivedData"
APP="$DERIVED/Build/Products/Debug-iphoneos/WisprFree.app"
BUNDLE_ID=com.deanbaker.wisprfree
GROUP_ID=group.com.deanbaker.wisprfree

device() {
  if [[ -n "${DEVICE:-}" ]]; then echo "$DEVICE"; return; fi
  local json rc=0; json=$(mktemp)
  xcrun devicectl list devices --json-output "$json" >/dev/null
  /usr/bin/python3 -I - "$json" <<'PY' || rc=$?
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
phys = [d for d in devs if d.get("hardwareProperties", {}).get("reality") != "simulated"
        and d.get("hardwareProperties", {}).get("platform") == "iOS"]
if not phys:
    sys.exit("No physical iPhone found. Connect it by USB and unlock it.")
print(phys[0]["hardwareProperties"]["udid"])
PY
  rm -f "$json"
  return $rc
}

case "${1:-}" in build|install|launch|log) dev=$(device) ;; esac

case "${1:-}" in
  team)
    printf 'DEVELOPMENT_TEAM = %s\n' "${2:?team id}" > "$PROJ/Config/Local.xcconfig"
    cat "$PROJ/Config/Local.xcconfig" ;;
  build)
    (cd "$PROJ" && xcodegen generate --quiet)
    xcodebuild -project "$PROJ/WisprFree.xcodeproj" -scheme WisprFree \
      -destination "id=$dev" -derivedDataPath "$DERIVED" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration build \
      | grep -E "error:|warning: .*/App/|BUILD (SUCCEEDED|FAILED)" ;;
  install)
    xcrun devicectl device install app --device "$dev" "$APP" | tail -3 ;;
  launch)
    xcrun devicectl device process launch --device "$dev" --terminate-existing "$BUNDLE_ID" ;;
  log)
    out=$(mktemp -d)
    xcrun devicectl device copy from --device "$dev" --domain-type appGroupDataContainer \
      --domain-identifier "$GROUP_ID" --source Library/Caches/debug.log --destination "$out/debug.log" >/dev/null
    tail -n "${2:-60}" "$out/debug.log"
    rm -rf "${out:?}" ;;
  *)
    sed -n 2,8p "$0"; exit 1 ;;
esac
