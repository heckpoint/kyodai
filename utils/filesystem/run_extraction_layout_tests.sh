#!/usr/bin/env bash
# Runs against a minimal project with stub autoloads and an isolated user://.
# Never point the test runner at the production Kyodai project: Godot starts
# project autoloads even in -s mode, which can mutate real application data.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
test_script="${1:-run_extraction_layout_tests.gd}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/kyodai-extraction-layout-tests.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

mkdir -p \
  "$test_root/utils" \
  "$test_root/utils/sync" \
  "$test_root/managers/system_manager" \
  "$test_root/base_class/abstract" \
  "$test_root/data" \
  "$test_root/stubs" \
  "$test_root/xdg-data" \
  "$test_root/xdg-config"

ln -s "$repo_root/utils/filesystem" "$test_root/utils/filesystem"
ln -s "$repo_root/utils/sync/content_hash.gd" "$test_root/utils/sync/content_hash.gd"
ln -s "$repo_root/data/emulators" "$test_root/data/emulators"
ln -s "$repo_root/managers/system_manager/filesystem_sub_manager.gd" "$test_root/managers/system_manager/filesystem_sub_manager.gd"
ln -s "$repo_root/base_class/abstract/manager.gd" "$test_root/base_class/abstract/manager.gd"

cat > "$test_root/project.godot" <<'EOF'
config_version=5

[application]
config/name="KyodaiExtractionLayoutTestsIsolated"
config/features=PackedStringArray("4.7")

[autoload]
SystemManager="*res://stubs/system_manager.gd"
LaunchManager="*res://stubs/empty_manager.gd"
DataManager="*res://stubs/empty_manager.gd"
EOF

cat > "$test_root/stubs/platform.gd" <<'EOF'
extends RefCounted

func is_android() -> bool:
	return false

func is_linux() -> bool:
	return true

func is_windows() -> bool:
	return false

func get_platform_name() -> String:
	return "Linux"
EOF

cat > "$test_root/stubs/system_manager.gd" <<'EOF'
extends Node

var platform = preload("res://stubs/platform.gd").new()
EOF

cat > "$test_root/stubs/empty_manager.gd" <<'EOF'
extends Node
EOF

cat > "$test_root/stubs/memory_sub_manager.gd" <<'EOF'
class_name MemorySubManager
extends Node

static func is_shutting_down() -> bool:
	return false
EOF

export XDG_DATA_HOME="$test_root/xdg-data"
export XDG_CONFIG_HOME="$test_root/xdg-config"

"$godot_bin" --headless --path "$test_root" --import
"$godot_bin" --headless --path "$test_root" --check-only -s "utils/filesystem/$test_script"
set -o pipefail
"$godot_bin" --headless --path "$test_root" --quit-after 120 -s "utils/filesystem/$test_script" 2>&1 | tee "$test_root/results.log"
if [[ "$test_script" == "run_extraction_layout_tests.gd" ]]; then
  grep -Eq '\[extraction-layout\] [0-9]+/[0-9]+ checks passed, 0 failed' "$test_root/results.log"
fi
