#!/usr/bin/env bash
# Runs VStreamKit's tests with coverage and prints line coverage per source file, merged across
# every test target (`swift test --show-codecov-path` only covers the first test bundle).
#
#   scripts/coverage.sh            # summary table
#   scripts/coverage.sh --html     # also writes build/coverage/index.html
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "${repository_root}/VStreamKit"

swift test --enable-code-coverage --quiet >/dev/null

products="$(dirname "$(swift test --show-codecov-path)")/.."
profile="${products}/codecov/default.profdata"
binaries=()
for bundle in "${products}"/*Tests.xctest; do
    name="$(basename "${bundle}" .xctest)"
    binaries+=("${bundle}/Contents/MacOS/${name}")
done

arguments=("${binaries[0]}")
for binary in "${binaries[@]:1}"; do arguments+=(-object "${binary}"); done
ignore='(Tests/|DerivedSources|checkouts|MPVKit|nuvio-engine)'

xcrun llvm-cov report -instr-profile "${profile}" "${arguments[@]}" -ignore-filename-regex="${ignore}" \
    | sed -E 's#^/.*/Sources/##'

if [[ "${1:-}" == "--html" ]]; then
    output="${repository_root}/build/coverage"
    xcrun llvm-cov show -format=html -output-dir="${output}" -instr-profile "${profile}" "${arguments[@]}" \
        -ignore-filename-regex="${ignore}"
    echo "HTML report: ${output}/index.html"
fi
