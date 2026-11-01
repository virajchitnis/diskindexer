#!/bin/sh
# Fails if a coverage total is below the minimum.
#   scripts/check-coverage.sh go    <go-coverprofile> <min-percent>
#   scripts/check-coverage.sh swift <apple-package-dir> <min-percent>
# Swift counts the app logic only (views are covered by the UI tests).
set -eu
kind=$1 src=$2 min=$3

case $kind in
go)
	pct=$(go tool cover -func="$src" | awk '/^total:/ { sub(/%/, "", $NF); print $NF }')
	label="Go (all packages)"
	;;
swift)
	cd "$src"
	bin_dir=$(swift build --show-bin-path)
	prof="$(dirname "$(swift test --show-codecov-path)")/default.profdata"
	bin="$bin_dir/DiskIndexerPackageTests.xctest/Contents/MacOS/DiskIndexerPackageTests"
	report=$(xcrun llvm-cov report "$bin" -instr-profile="$prof" \
		-ignore-filename-regex='(/Tests/|/\.build/|/Views/|/DiskIndexerMac/)' \
		-show-region-summary=false -show-branch-summary=false -show-functions=false)
	echo "$report" | sed 's#^.*/Sources/##'
	pct=$(echo "$report" | awk '/^TOTAL/ { sub(/%/, "", $NF); print $NF }')
	label="Swift app logic (DiskIndexerKit, excluding views)"
	;;
*)
	echo "usage: $0 go|swift <source> <min-percent>" >&2
	exit 2
	;;
esac

if [ -z "$pct" ]; then
	echo "could not read a coverage total" >&2
	exit 2
fi
if awk -v p="$pct" -v m="$min" 'BEGIN { exit !(p + 0 >= m + 0) }'; then
	echo "$label coverage: $pct% (minimum $min%) ✓"
else
	echo "$label coverage: $pct% is below the $min% minimum ✗" >&2
	exit 1
fi
