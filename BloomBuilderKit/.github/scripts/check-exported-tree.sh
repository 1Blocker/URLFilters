#!/bin/sh
set -efu

# Run from the package root. Extra build arguments are whitespace-separated;
# shell quoting inside BLOOMBUILDER_BUILD_ARGS is not interpreted.
fail() {
  printf '%s\n' "Exported-tree check failed: $*" >&2
  exit 1
}

[ -f Package.swift ] || fail "run this script from the package root"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/bloombuilder-export.XXXXXX")
trap 'rm -rf "$work_dir"' 0
trap 'exit 1' HUP INT TERM

exported_tree=$(mktemp -d "$work_dir/source.XXXXXX")
tar --exclude=.git --exclude=.build --exclude=.swiftpm \
  --exclude=DerivedData --exclude=build --exclude=xcuserdata \
  --exclude='*.dSYM' --exclude='*.xcresult' --exclude=.DS_Store \
  -cf "$work_dir/source.tar" .
tar -xf "$work_dir/source.tar" -C "$exported_tree"
cp -R "$exported_tree" "$work_dir/reference"

cd "$exported_tree"
build_dir="$work_dir/build"
swift build ${BLOOMBUILDER_BUILD_ARGS:-} -c release --product bloombuilder \
  --scratch-path "$build_dir"
bin_dir=$(swift build ${BLOOMBUILDER_BUILD_ARGS:-} -c release \
  --product bloombuilder --scratch-path "$build_dir" --show-bin-path)

example_dir="$work_dir"
printf '%s\n' 'alpha.example' 'beta.example/path?query=1' 'gamma.example' \
  > "$example_dir/keys.txt"
"$bin_dir/bloombuilder" --bit-count 37 --hash-count 5 \
  --murmur-seed 305419896 --output "$example_dir/filter.bin" \
  "$example_dir/keys.txt"

printf '\140\112\101\300\005' > "$example_dir/expected.bin"
cmp "$example_dir/expected.bin" "$example_dir/filter.bin" \
  || fail "output differs from the documented vector"
diff -r "$work_dir/reference" "$exported_tree" \
  || fail "building or running changed the exported tree"
printf '%s\n' \
  'Exported-tree check passed: vector matches; source copy is unchanged.'
