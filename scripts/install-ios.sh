#!/usr/bin/env bash
# Builds VStream-iOS and installs it on a paired iPhone/iPad, over USB or Wi-Fi (same network,
# device unlocked). Free Apple IDs sign for 7 days; rerun this to renew.
#
#   scripts/install-ios.sh            # first paired physical device
#   scripts/install-ios.sh <UDID>     # a specific device
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${repository_root}"

device="${1:-}"
if [[ -z "${device}" ]]; then
    # First physical device CoreDevice knows about (simulators are marked "simulated").
    device="$(xcrun devicectl list devices 2>/dev/null \
        | awk '!/simulated/ && match($0, /[0-9A-F]{8}-[0-9A-F]{16}/) { print substr($0, RSTART, RLENGTH); exit }')"
fi
if [[ -z "${device}" ]]; then
    echo "No paired iPhone/iPad found. Connect it once by cable and trust this Mac." >&2
    exit 1
fi

xcodegen generate --quiet
xcodebuild -project VStream.xcodeproj -scheme VStream-iOS -configuration Release \
    -destination "id=${device}" \
    -derivedDataPath build/iOSDevice -clonedSourcePackagesDirPath build/SourcePackages \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    build | grep -E "error:|BUILD" || true

app="build/iOSDevice/Build/Products/Release-iphoneos/VStream.app"
xcrun devicectl device install app --device "${device}" "${app}"
xcrun devicectl device process launch --device "${device}" com.vstream.app >/dev/null 2>&1 \
    || echo "Installed. If it doesn't open: Settings → General → VPN & Device Management → Trust."
