#!/usr/bin/env bash
# Checks the structural invariants of the portable settings schema.
#
# The same linter runs inside `swift test`; this script exists so the check also
# works on a tree that does not compile, which is exactly the tree a bad
# settings merge produces. It compiles one self-contained file, so it answers in
# a couple of seconds rather than after a full package build.
#
# Nothing here pipes a command whose exit status matters. `cmd | tail` reports
# tail's status, and that is how the first broken settings merge was waved
# through by a build that had already failed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
linter_source="$repo_root/tests/KurottyRenderingTests/SettingsSchemaLinter.swift"

if [ ! -f "$linter_source" ]; then
  echo "check-settings-schema: linter source missing at $linter_source" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let findings = try SettingsSchemaLinter.lintRepository(at: root)
    guard findings.isEmpty else {
        FileHandle.standardError.write(Data(
            "settings schema: \(findings.count) invariant violation(s)\n".utf8
        ))
        for finding in findings {
            FileHandle.standardError.write(Data("  \(finding)\n".utf8))
        }
        exit(1)
    }
    print("settings schema: invariants hold")
} catch {
    FileHandle.standardError.write(Data("settings schema: \(error)\n".utf8))
    exit(1)
}
SWIFT

swiftc -O -o "$work_dir/check-settings-schema" "$linter_source" "$work_dir/main.swift"
"$work_dir/check-settings-schema" "$repo_root"
