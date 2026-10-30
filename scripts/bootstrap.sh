#!/usr/bin/env bash
# Prepares sibling dependencies (MPVKit, nuvio-engine) and generates the Xcode project.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
parent_root="$(dirname "${repository_root}")"

engine_version=0.1.6
engine_checksum=f556718ec0fd122a61bc5408307b19fcd54397595954c46c6ff8db1e5a179421
engine_root="${VSTREAM_ENGINE_ROOT:-${parent_root}/nuvio-engine}"
engine_framework="${engine_root}/platform/apple/NuvioEngine.xcframework"
mpvkit_root="${VSTREAM_MPVKIT_ROOT:-${parent_root}/MPVKit}"

clone_if_missing() {
    local path="$1" url="$2"
    if [[ ! -d "${path}/.git" ]]; then
        git clone --depth 1 "${url}" "${path}"
    fi
}

clone_if_missing "${mpvkit_root}" https://github.com/mpvkit/MPVKit.git
clone_if_missing "${engine_root}" https://github.com/NuvioMedia/nuvio-engine.git

if [[ ! -f "${engine_framework}/macos-arm64_x86_64/libCNuvioEngine.a" ]]; then
    temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/vstream-bootstrap.XXXXXX")"
    trap 'rm -rf "${temporary_directory}"' EXIT

    archive="${temporary_directory}/nuvio-engine-apple-${engine_version}.zip"
    curl --fail --location --retry 5 --retry-all-errors --silent --show-error \
        --output "${archive}" \
        "https://github.com/NuvioMedia/nuvio-engine/releases/download/v${engine_version}/nuvio-engine-apple-${engine_version}.zip"

    actual_checksum="$(shasum -a 256 "${archive}" | awk '{print $1}')"
    if [[ "${actual_checksum}" != "${engine_checksum}" ]]; then
        echo "Nuvio Engine Apple package checksum mismatch." >&2
        exit 1
    fi

    unzip -q "${archive}" -d "${temporary_directory}/extracted"
    source_framework="$(find "${temporary_directory}/extracted" -type d -name NuvioEngine.xcframework -print -quit)"
    if [[ ! -f "${source_framework}/macos-arm64_x86_64/libCNuvioEngine.a" ]]; then
        echo "Nuvio Engine Apple package does not contain the macOS library." >&2
        exit 1
    fi
    rm -rf "${engine_framework}"
    ditto "${source_framework}" "${engine_framework}"
fi

# Sign with the first Xcode team (Xcode → Settings → Accounts) so the Keychain keeps trusting
# the app across rebuilds. Ad-hoc signatures change every build.
local_config="${repository_root}/Config/Local.xcconfig"
if [[ ! -f "${local_config}" ]]; then
    team_id="$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
        | sed -nE 's/.*teamID = "?([A-Z0-9]{10})"?;.*/\1/p' | head -1)"
    if [[ -n "${team_id}" ]]; then
        printf 'DEVELOPMENT_TEAM = %s\nCODE_SIGN_IDENTITY = Apple Development\n' "${team_id}" > "${local_config}"
        echo "Signing with team ${team_id} (Config/Local.xcconfig)"
    else
        echo "No Xcode team found; building ad-hoc (Keychain will prompt after each rebuild)." >&2
    fi
fi

if ! command -v xcodegen >/dev/null; then
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
fi
(cd "${repository_root}" && xcodegen generate --quiet)
echo "Ready: open ${repository_root}/VStream.xcodeproj"
