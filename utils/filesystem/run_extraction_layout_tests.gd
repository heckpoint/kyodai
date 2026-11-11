## Headless tests for extraction-layout planning and filesystem normalization.
## Usage: utils/filesystem/run_extraction_layout_tests.sh
## The shell harness creates an isolated project; do not run this script against
## the production project because Godot would also start its real autoloads.
extends SceneTree

const Layout = preload("res://utils/filesystem/extraction_layout.gd")
const EmulatorExtraction = preload("res://utils/filesystem/emulator_extraction.gd")
const GameExtraction = preload("res://utils/filesystem/game_extraction.gd")
const SaveLayout = preload("res://utils/filesystem/save_layout.gd")
const OperationLifecycle = preload("res://utils/filesystem/operation_lifecycle.gd")

var FSM: GDScript
var ContentHash: GDScript
var _checks := 0
var _failures := 0
var _temp_root := ""
var _strip_registry_count := 0

func _init() -> void:
	# SceneTree scripts are compiled before autoload names are registered. Load
	# FSM on the first idle turn so its normal SystemManager references resolve.
	call_deferred("_run")

func _run() -> void:
	FSM = load("res://managers/system_manager/filesystem_sub_manager.gd")
	ContentHash = load("res://utils/sync/content_hash.gd")
	_run_planner_tests()
	_run_emulator_registry_tests()
	_run_game_policy_tests()
	_run_save_policy_tests()
	_run_filesystem_tests()
	_run_3ds_tests()
	_run_content_hash_tests()
	_run_lifecycle_tests()
	if _temp_root != "" and FSM.dir_exists(_temp_root):
		FSM.delete_dir_recursive(_temp_root)
	print("[extraction-layout] %d/%d checks passed, %d failed" % [_checks - _failures, _checks, _failures])
	quit(1 if _failures > 0 else 0)

func _run_planner_tests() -> void:
	_expect_plan("already flat", ["bios.bin"], {"expected_any": ["bios.bin"]}, Layout.STATUS_ALREADY_CANONICAL, "")
	_expect_plan("single wrapper", ["wrapper/bios.bin"], {"expected_any": ["bios.bin"]}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("multiple wrappers", ["one/two/three/bios.bin"], {"expected_any": ["bios.bin"]}, Layout.STATUS_HOIST, "one/two/three")
	_expect_plan("sibling file does not block wrapper", ["readme.txt", "wrapper/bios.bin"], {"expected_any": ["bios.bin"]}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("macOS metadata ignored", ["__MACOSX/._bios.bin", "wrapper/bios.bin"], {"expected_any": ["bios.bin"]}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("ambiguous sibling payloads", ["one/bios.bin", "two/bios.bin"], {"expected_any": ["bios.bin"]}, Layout.STATUS_AMBIGUOUS)
	_expect_plan("shallowest unique payload wins", ["wrapper/bios.bin", "wrapper/nested/bios.bin"], {"expected_any": ["bios.bin"]}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("maximum depth enforced", ["one/two/three/bios.bin"], {"expected_any": ["bios.bin"], "max_depth": 2}, Layout.STATUS_PAYLOAD_MISSING)
	_expect_plan("all anchors present", ["wrapper/a.bin", "wrapper/b.bin"], {"expected_all": ["a.bin", "b.bin"]}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("all anchors rejects partial payload", ["wrapper/a.bin"], {"expected_all": ["a.bin", "b.bin"]}, Layout.STATUS_PAYLOAD_MISSING)
	_expect_plan("any anchor accepts alternative", ["wrapper/b.bin"], {"expected_any": ["a.bin", "b.bin"]}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("nested expected subpath", ["wrapper/dc/dc_boot.bin"], {"expected_any": ["dc/dc_boot.bin"]}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("expected glob", ["wrapper/cores/core.dll"], {"expected_any": ["cores/*.dll"]}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("glob does not cross path segments", ["wrapper/cores/nested/core.dll"], {"expected_any": ["cores/*.dll"]}, Layout.STATUS_PAYLOAD_MISSING)
	_expect_plan("target folder glob", ["RetroArch-Linux-x86_64/retroarch"], {"target_folder": "RetroArch-*"}, Layout.STATUS_HOIST, "RetroArch-Linux-x86_64")
	_expect_plan("target folder ambiguity", ["RetroArch-one/retroarch", "RetroArch-two/retroarch"], {"target_folder": "RetroArch-*"}, Layout.STATUS_AMBIGUOUS)
	_expect_plan("optional target accepts already flat", ["retroarch"], {"target_folder": "RetroArch-*", "allow_missing_target": true}, Layout.STATUS_ALREADY_CANONICAL, "")
	_expect_plan("anchorless single root fallback", ["wrapper/program.exe"], {"strip_single_root": true}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("anchorless siblings are ambiguous", ["wrapper/program.exe", "readme.txt"], {"strip_single_root": true}, Layout.STATUS_AMBIGUOUS)
	_expect_plan("case sensitive anchor", ["wrapper/Boot.BIN"], {"expected_any": ["boot.bin"]}, Layout.STATUS_PAYLOAD_MISSING)
	_expect_plan("case insensitive anchor", ["wrapper/Boot.BIN"], {"expected_any": ["boot.bin"], "case_sensitive": false}, Layout.STATUS_HOIST, "wrapper")
	_expect_plan("backslash entry normalized", ["wrapper\\bios.bin"], {"expected_any": ["bios.bin"]}, Layout.STATUS_HOIST, "wrapper")

	for path in ["../bios.bin", "/absolute/bios.bin", "C:/drive/bios.bin", "..\\evil.bin"]:
		_expect_plan("unsafe entry " + path, [path], {"expected_any": ["bios.bin"]}, Layout.STATUS_UNSAFE_ENTRY)
	_expect_plan("file-directory collision", ["payload", "payload/bios.bin"], {"expected_any": ["bios.bin"]}, Layout.STATUS_UNSAFE_ENTRY)
	_expect_plan("unsafe expected anchor", ["wrapper/bios.bin"], {"expected_any": ["../bios.bin"]}, Layout.STATUS_UNSAFE_ENTRY)

func _run_emulator_registry_tests() -> void:
	_strip_registry_count = 0
	for file_name in DirAccess.get_files_at("res://data/emulators"):
		if not file_name.ends_with(".json"):
			continue
		var path := "res://data/emulators/" + file_name
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		_expect(data != null, "registry JSON parses: " + file_name)
		if data != null:
			_walk_emulator_registry(data, file_name)
	_expect(_strip_registry_count == 11, "exactly eleven strip-enabled emulator configs migrated")

func _walk_emulator_registry(node, source_name: String) -> void:
	if node is Dictionary:
		if bool(node.get("strip_top_directory", false)):
			_strip_registry_count += 1
			var options := EmulatorExtraction.layout_options(node)
			var anchors: Array = EmulatorExtraction.expected_anchors(node)
			var target := str(options.get("target_folder", ""))
			_expect(str(node.get("extract_to", ".")) == ".", source_name + ": strip extraction stays at emulator root")
			if target == "":
				_expect(anchors.size() == 1, source_name + ": executable anchor derived")
				if anchors.size() == 1:
					var wrapped := Layout.plan(["wrapper/" + str(anchors[0])], options)
					_expect(str(wrapped.get("status", "")) == Layout.STATUS_HOIST, source_name + ": wrapped executable selected")
					var flat := Layout.plan([str(anchors[0])], options)
					_expect(str(flat.get("status", "")) == Layout.STATUS_ALREADY_CANONICAL, source_name + ": flat executable accepted")
			else:
				_expect(bool(options.get("allow_missing_target", false)), source_name + ": targeted folder permits flat archive")
				_expect(anchors.size() == 1, source_name + ": targeted payload anchor derived")
				var wrapped := Layout.plan([target + "/RetroArch.AppImage"], options)
				_expect(str(wrapped.get("status", "")) == Layout.STATUS_HOIST, source_name + ": targeted folder selected")
				var flat := Layout.plan(["RetroArch.AppImage"], options)
				_expect(str(flat.get("status", "")) == Layout.STATUS_ALREADY_CANONICAL, source_name + ": targeted flat archive accepted")
				var wrong_wrapper := Layout.plan(["WrongWrapper/RetroArch.AppImage"], options)
				_expect(str(wrong_wrapper.get("status", "")) == Layout.STATUS_PAYLOAD_MISSING, source_name + ": nested-only target miss rejected")
		for value in node.values():
			_walk_emulator_registry(value, source_name)
	elif node is Array:
		for value in node:
			_walk_emulator_registry(value, source_name)

func _run_game_policy_tests() -> void:
	var options := GameExtraction.app_layout_options()
	_expect_plan("app payload already flat", ["sce_sys/param.sfo", "eboot.bin"], options, Layout.STATUS_ALREADY_CANONICAL, "")
	_expect_plan("app payload outer and title wrappers", ["outer/PCSE00965/sce_sys/param.sfo", "outer/PCSE00965/eboot.bin"], options, Layout.STATUS_HOIST, "outer/PCSE00965")
	_expect_plan("app payload missing executable", ["outer/PCSE00965/sce_sys/param.sfo"], options, Layout.STATUS_PAYLOAD_MISSING)
	_expect_plan("app payload ambiguous title roots", ["one/PCSE00965/sce_sys/param.sfo", "one/PCSE00965/eboot.bin", "two/PCSE00965/sce_sys/param.sfo", "two/PCSE00965/eboot.bin"], options, Layout.STATUS_AMBIGUOUS)

	var ps4 := GameExtraction.ps4_title_id_candidate("outer/more/CUSA67890/sce_sys/param.sfo")
	_expect(str(ps4.get("title_id", "")) == "CUSA67890" and int(ps4.get("depth", -1)) == 2, "PS4 TitleID found through outer wrappers")
	ps4 = GameExtraction.ps4_title_id_candidate("outer\\CUSA01130\\sce_sys\\param.sfo")
	_expect(str(ps4.get("title_id", "")) == "CUSA01130", "PS4 TitleID backslash path")
	_expect(GameExtraction.ps4_title_id_candidate("outer/CUSA12x45/file").is_empty(), "PS4 invalid TitleID rejected")
	ps4 = GameExtraction.ps4_title_id_candidate("outer/CUSA11111/nested/CUSA22222/file")
	_expect(str(ps4.get("title_id", "")) == "CUSA11111", "PS4 shallowest segment wins")

	_expect(GameExtraction.ps4_title_id_is_valid("CUSA01130"), "PS4 strict cleanup TitleID accepted")
	for invalid in ["", "cusa01130", "CUSA1234", "CUSA01130X", "../CUSA01130", "CUSA01130/other", "/CUSA01130"]:
		_expect(not GameExtraction.ps4_title_id_is_valid(invalid), "PS4 cleanup TitleID rejected: " + invalid)
	_expect(GameExtraction.ps4_owned_root("/games/ps4", "CUSA01130") == "/games/ps4/CUSA01130", "PS4 owned root is deterministic")
	_expect(GameExtraction.ps4_owned_root("/games/ps4", "../CUSA01130") == "", "PS4 owned root rejects traversal")
	var ps4_staging := GameExtraction.staging_path("/games/ps4/CUSA01130", "CUSA01130")
	_expect(ps4_staging.get_file().begins_with(".kyodai-extract-CUSA01130-") and GameExtraction.is_staging_path(ps4_staging), "PS4 staging is title-scoped and recognized")
	_expect(GameExtraction.ps4_artifact_owned(".kyodai-backup-CUSA01130-123_1", "CUSA01130"), "PS4 backup artifact matched")
	_expect(GameExtraction.ps4_artifact_owned(".kyodai-hoist-.kyodai-extract-CUSA01130-123_1-456_2", "CUSA01130"), "PS4 hoist artifact matched")
	_expect(not GameExtraction.ps4_artifact_owned(".kyodai-extract-CUSA01130X-123_1", "CUSA01130"), "PS4 artifact matching rejects prefix lookalike")
	_expect(not GameExtraction.ps4_artifact_owned(".kyodai-extract-123_1", "CUSA01130"), "PS4 cleanup leaves anonymous legacy staging")

	_expect(GameExtraction.is_ps3_disc_sfo_path("wrapper/Game/PS3_GAME/PARAM.SFO"), "PS3 archive disc SFO recognized")
	_expect(not GameExtraction.is_ps3_disc_sfo_path("wrapper/Update/PARAM.SFO"), "PS3 decoy SFO is not authoritative")
	var ps3 := GameExtraction.ps3_layout_from_sfo("wrapper/Game/PS3_GAME/PARAM.SFO")
	_expect(bool(ps3.get("is_disc", false)) and str(ps3.get("game_root", "")) == "wrapper/Game", "PS3 disc root selection")
	ps3 = GameExtraction.ps3_layout_from_sfo("wrapper/BLUS12345/PARAM.SFO")
	_expect(not bool(ps3.get("is_disc", true)) and str(ps3.get("game_root", "")) == "wrapper/BLUS12345", "PS3 digital root selection")

func _run_save_policy_tests() -> void:
	var layout := SaveLayout.policy("pcsx2", "ps2")
	_expect(str(layout["kind"]) == SaveLayout.BARE_CONTENTS and str(layout["zip_root_mode"]) == SaveLayout.ZIP_ROOT_NONE, "PCSX2 bare archive and hash root match")
	layout = SaveLayout.policy("ppsspp", "psp")
	_expect(str(layout["kind"]) == SaveLayout.MULTI_ROOT and str(layout["commit"]) == SaveLayout.COMMIT_REPLACE_COMPONENTS, "PSP multi-root component policy")
	layout = SaveLayout.policy("dolphin", "ngc")
	_expect(str(layout["kind"]) == SaveLayout.BARE_CONTENTS and str(layout["commit"]) == SaveLayout.COMMIT_MERGE, "GameCube shared card merge policy")
	layout = SaveLayout.policy("dolphin", "wii")
	_expect(str(layout["commit"]) == SaveLayout.COMMIT_REPLACE, "Wii owned title replacement policy")
	layout = SaveLayout.policy("vita3k", "psvita")
	_expect(str(layout["kind"]) == SaveLayout.NAMED_ROOT and str(layout["zip_root_mode"]) == SaveLayout.ZIP_ROOT_SOURCE_BASENAME, "Vita named-root upload and restore policy")
	layout = SaveLayout.policy("retroarch", "psp")
	_expect(str(layout["kind"]) == SaveLayout.MULTI_ROOT and str(layout["zip_root_mode"]) == SaveLayout.ZIP_ROOT_COMPONENTS, "RetroArch PSP component hash policy")
	layout = SaveLayout.policy("azahar", "3ds")
	_expect(str(layout["kind"]) == SaveLayout.ROUTED_COMPONENTS and str(layout["commit"]) == SaveLayout.COMMIT_ROUTED, "3DS routed component policy")
	layout = SaveLayout.policy("unknown-emulator", "unknown")
	_expect(str(layout["kind"]) == SaveLayout.BARE_CONTENTS and str(layout["commit"]) == SaveLayout.COMMIT_MERGE, "unknown emulator generic merge fallback")

func _run_filesystem_tests() -> void:
	_temp_root = "user://temp/extraction_layout_tests_" + str(Time.get_ticks_msec()) + "_" + str(randi())
	_expect(FSM.make_dir_recursive(_temp_root), "create test root")

	var nested := _temp_root + "/nested"
	_write(nested + "/outer/inner/bios.bin", "bios")
	_write(nested + "/outer/inner/data/state.bin", "state")
	_write(nested + "/library-note.txt", "keep")
	var result: Dictionary = FSM.normalize_extraction_root(nested, ["bios.bin"])
	_expect_status("filesystem nested normalization", result, "normalized")
	_expect(result.get("path", "") == nested, "normalization returns final target path")
	_expect(result.get("source_path", "") == nested + "/outer/inner", "normalization reports discovered source")
	_expect(FSM.file_exists(nested + "/bios.bin"), "nested anchor hoisted")
	_expect(FSM.file_exists(nested + "/data/state.bin"), "nested payload siblings hoisted")
	_expect(FSM.file_exists(nested + "/library-note.txt"), "unrelated root file preserved")
	_expect(not FSM.dir_exists(nested + "/outer"), "empty wrapper chain removed")
	result = FSM.normalize_extraction_root(nested, ["bios.bin"])
	_expect_status("filesystem rerun idempotent", result, "already_canonical")
	_expect(not result.get("moved", true), "canonical rerun does not move files")

	var collision := _temp_root + "/collision"
	_write(collision + "/wrapper/bios.bin", "new bios")
	_write(collision + "/wrapper/config.ini", "new config")
	_write(collision + "/config.ini", "old config")
	result = FSM.normalize_extraction_root(collision, ["bios.bin"])
	_expect_status("filesystem collision rejected", result, "collision")
	_expect(not FSM.file_exists(collision + "/bios.bin"), "collision does not move anchor")
	_expect(FSM.file_exists(collision + "/wrapper/bios.bin"), "collision leaves source payload intact")
	_expect(_read(collision + "/config.ini") == "old config", "collision leaves destination content intact")
	_expect(_read(collision + "/wrapper/config.ini") == "new config", "collision leaves source content intact")

	var missing := _temp_root + "/missing"
	_write(missing + "/wrapper/other.bin", "other")
	result = FSM.normalize_extraction_root(missing, ["bios.bin"])
	_expect_status("filesystem missing payload", result, Layout.STATUS_PAYLOAD_MISSING)
	_expect(FSM.file_exists(missing + "/wrapper/other.bin"), "missing payload leaves tree untouched")

	var targeted := _temp_root + "/targeted"
	_write(targeted + "/RetroArch-Linux-x86_64/retroarch", "binary")
	result = FSM.normalize_extraction_layout(targeted, {"target_folder": "RetroArch-*"})
	_expect_status("filesystem targeted folder", result, "normalized")
	_expect(FSM.file_exists(targeted + "/retroarch"), "targeted payload hoisted")

	var subpath := _temp_root + "/subpath"
	_write(subpath + "/wrapper/dc/dc_boot.bin", "dreamcast")
	result = FSM.normalize_extraction_root(subpath, ["dc/dc_boot.bin"])
	_expect_status("filesystem expected subpath", result, "normalized")
	_expect(FSM.file_exists(subpath + "/dc/dc_boot.bin"), "expected subpath preserved at final root")

	if OS.get_name() != "Windows":
		var backslash := _temp_root + "/backslash"
		_expect(_write_literal(backslash + "/wrapper/inner\\bios.bin", "bios"), "create literal backslash fixture")
		_expect(FSM.list_dir(backslash + "/wrapper").has("inner\\bios.bin"), "nested literal backslash fixture created")
		result = FSM.normalize_extraction_root(backslash, ["bios.bin"])
		_expect_status("filesystem nested backslash repair", result, "normalized")
		_expect(FSM.file_exists(backslash + "/bios.bin"), "nested backslash payload normalized and hoisted")

		var root_backslash := _temp_root + "/root_backslash"
		_expect(_write_literal(root_backslash + "/dc\\dc_boot.bin", "dreamcast"), "create root literal backslash fixture")
		result = FSM.normalize_extraction_root(root_backslash, ["dc/dc_boot.bin"])
		_expect_status("root backslash anchor repairs before canonical return", result, "already_canonical")
		_expect(FSM.file_exists(root_backslash + "/dc/dc_boot.bin"), "root backslash anchor becomes physical nested path")

		var dot_backslash := _temp_root + "/dot_backslash"
		_expect(_write_literal(dot_backslash + "/.\\bios.bin", "bios"), "create dot-prefixed backslash fixture")
		_expect(FSM.list_dir(dot_backslash).has(".\\bios.bin"), "dot-prefixed literal file is visible to directory listing")
		result = FSM.normalize_extraction_root(dot_backslash, ["bios.bin"])
		_expect_status("dot-prefixed backslash anchor repairs", result, "already_canonical")
		_expect(FSM.file_exists(dot_backslash + "/bios.bin"), "dot-prefixed backslash becomes root anchor")

		var mixed_backslash := _temp_root + "/mixed_backslash"
		_write(mixed_backslash + "/bios.bin", "bios")
		_expect(_write_literal(mixed_backslash + "/unrelated\\note.bin", "note"), "create unrelated root backslash fixture")
		result = FSM.normalize_extraction_root(mixed_backslash, ["bios.bin"])
		_expect_status("valid root anchor keeps canonical status after sibling repair", result, "already_canonical")
		_expect(FSM.file_exists(mixed_backslash + "/unrelated/note.bin"), "canonical fast path repairs unrelated backslash entries")

	var disjoint := _temp_root + "/disjoint"
	_write(disjoint + "/wrapper/bios.bin", "new bios")
	_write(disjoint + "/wrapper/dc/new.bin", "new")
	_write(disjoint + "/dc/existing.bin", "existing")
	result = FSM.normalize_extraction_root(disjoint, ["bios.bin"])
	_expect_status("filesystem disjoint directory merge", result, "normalized")
	_expect(FSM.file_exists(disjoint + "/dc/new.bin"), "disjoint source file merged")
	_expect(FSM.file_exists(disjoint + "/dc/existing.bin"), "disjoint existing file preserved")

	var staged := _temp_root + "/staged"
	var live := _temp_root + "/live"
	_write(staged + "/wrapper/private/movable.sed", "downloaded identity")
	result = FSM.normalize_extraction_root(staged, ["private/movable.sed"])
	_expect_status("filesystem staged force-pull payload", result, "normalized")
	_write(live + "/private/movable.sed", "generated identity")
	_write(live + "/private/unrelated.bin", "keep")
	var commit: Dictionary = FSM.merge_extraction_payload(staged, live)
	_expect_status("filesystem staged live commit", commit, "committed")
	_expect(_read(live + "/private/movable.sed") == "downloaded identity", "live generated anchor replaced by downloaded payload")
	_expect(FSM.file_exists(live + "/private/unrelated.bin"), "live unrelated firmware preserved")
	_expect(not FSM.dir_exists(staged), "successful commit removes staging")

	var emulator_staged := _temp_root + "/emulator_staged"
	var emulator_live := _temp_root + "/emulator_live"
	var emulator_config := {
		"extract_to": ".",
		"validate": {"action_type": "file_exists", "file": "Dolphin.exe"},
	}
	_write(emulator_staged + "/wrapper/Dolphin.exe", "new executable")
	_write(emulator_live + "/Dolphin.exe", "old executable")
	result = FSM.normalize_extraction_layout(emulator_staged, EmulatorExtraction.layout_options(emulator_config))
	_expect_status("emulator wrapped update normalized in staging", result, "normalized")
	commit = FSM.merge_extraction_payload(emulator_staged, emulator_live, bool(result.get("scan_complete", false)), result.get("entries", []))
	_expect_status("emulator wrapped update committed", commit, "committed")
	_expect(_read(emulator_live + "/Dolphin.exe") == "new executable", "stale live executable cannot mask wrapped update")

	var swap_staged := _temp_root + "/swap_staged"
	var swap_live := _temp_root + "/swap_live"
	_write(swap_staged + "/wrapper/Dolphin.exe", "new executable")
	for index in range(70):
		_write(swap_staged + "/wrapper/files/new_%02d.bin" % index, "new")
	_write(swap_live + "/Dolphin.exe", "old executable")
	_write(swap_live + "/profiles/old.ini", "preserved")
	result = FSM.normalize_extraction_layout(swap_staged, EmulatorExtraction.layout_options(emulator_config))
	_expect_status("large snapshot merge normalized", result, "normalized")
	commit = FSM.merge_extraction_payload(swap_staged, swap_live, bool(result.get("scan_complete", false)), result.get("entries", []))
	_expect_status("large snapshot merge committed", commit, "committed")
	_expect(_read(swap_live + "/Dolphin.exe") == "new executable", "swap merge keeps new conflicting file")
	_expect(FSM.file_exists(swap_live + "/files/new_69.bin") and _read(swap_live + "/profiles/old.ini") == "preserved", "swap merge restores old-only files")
	_expect(not FSM.dir_exists(swap_staged), "swap merge consumes staging")

	var multi_staged := _temp_root + "/multi_staged"
	var multi_live := _temp_root + "/multi_live"
	_write(multi_staged + "/outer/inner/Dolphin.exe", "new executable")
	_write(multi_live + "/outer", "unrelated live file")
	result = FSM.normalize_extraction_layout(multi_staged, EmulatorExtraction.layout_options(emulator_config))
	_expect_status("multi-wrapper snapshot normalized", result, "normalized")
	var snapshot_paths: Array = []
	var snapshot_entries_exist := true
	for entry in result.get("entries", []):
		var relative := str(entry.get("path", ""))
		snapshot_paths.append(relative)
		if bool(entry.get("is_dir", false)):
			snapshot_entries_exist = snapshot_entries_exist and FSM.dir_exists(multi_staged + "/" + relative)
		else:
			snapshot_entries_exist = snapshot_entries_exist and FSM.file_exists(multi_staged + "/" + relative)
	_expect(snapshot_entries_exist, "multi-wrapper snapshot contains only entries that still exist")
	_expect(not snapshot_paths.has("outer"), "deleted wrapper ancestor absent from commit snapshot")
	commit = FSM.merge_extraction_payload(multi_staged, multi_live, bool(result.get("scan_complete", false)), result.get("entries", []))
	_expect_status("deleted wrapper ancestor cannot cause phantom collision", commit, "committed")
	_expect(_read(multi_live + "/outer") == "unrelated live file", "phantom wrapper collision does not affect unrelated live file")

	var snapshot_staged := _temp_root + "/snapshot_staged"
	var snapshot_live := _temp_root + "/snapshot_live"
	_write(snapshot_staged + "/wrapper/Dolphin.exe", "new executable")
	_write(snapshot_live + "/Dolphin.exe/old.bin", "directory collision")
	result = FSM.normalize_extraction_layout(snapshot_staged, EmulatorExtraction.layout_options(emulator_config))
	_expect_status("snapshot type collision normalized", result, "normalized")
	commit = FSM.merge_extraction_payload(snapshot_staged, snapshot_live, bool(result.get("scan_complete", false)), result.get("entries", []))
	_expect_status("snapshot preflight detects live type collision", commit, "collision")
	_expect(FSM.file_exists(snapshot_staged + "/Dolphin.exe"), "snapshot collision leaves staged payload intact")
	_expect(FSM.file_exists(snapshot_live + "/Dolphin.exe/old.bin"), "snapshot collision leaves live directory intact")

	var case_live := _temp_root + "/case_live"
	_write(case_live + "/foo/old.bin", "old")
	var case_collisions: Array = []
	var case_unsafe: Array = []
	var case_types: Array = []
	FSM._collect_extraction_commit_conflicts_from_snapshot([{"path": "Foo", "is_dir": false, "is_link": false}], "", case_live, case_collisions, case_unsafe, case_types, true)
	_expect(case_types.size() == 1, "case-folded snapshot rejects file/directory collision")
	_expect(case_unsafe.is_empty() and case_collisions.is_empty(), "case-folded type collision is not misreported as overwrite")
	_expect(FSM.file_exists(case_live + "/foo/old.bin"), "case-folded preflight leaves old content intact")

	var fresh_staged := _temp_root + "/fresh_staged"
	var fresh_live := _temp_root + "/fresh_live"
	_write(fresh_staged + "/title/game.bin", "game")
	commit = FSM.merge_extraction_payload(fresh_staged, fresh_live)
	_expect_status("filesystem fresh destination commit", commit, "committed")
	_expect(FSM.file_exists(fresh_live + "/title/game.bin"), "fresh destination payload committed")
	_expect(not FSM.dir_exists(fresh_staged), "fresh destination commit consumes staging")

	var app_staged := _temp_root + "/app_staged"
	var app_live := _temp_root + "/app_live"
	_write(app_staged + "/outer/PCSE00965/sce_sys/param.sfo", "sfo")
	_write(app_staged + "/outer/PCSE00965/eboot.bin", "eboot")
	result = FSM.normalize_extraction_layout(app_staged, GameExtraction.app_layout_options())
	_expect_status("game app payload normalized", result, "normalized")
	commit = FSM.replace_extraction_payload(app_staged, app_live)
	_expect_status("game app payload replaced", commit, "replaced")
	_expect(FSM.file_exists(app_live + "/sce_sys/param.sfo") and FSM.file_exists(app_live + "/eboot.bin"), "game app root contains direct anchors")

	var ps4_games := _temp_root + "/ps4_games"
	_write(ps4_games + "/CUSA01130/partial.bin", "partial")
	_write(ps4_games + "/.kyodai-extract-CUSA01130-100_1/staged.bin", "staged")
	_write(ps4_games + "/.kyodai-hoist-.kyodai-extract-CUSA01130-100_1-101_2/hoisted.bin", "hoisted")
	_write(ps4_games + "/.kyodai-backup-CUSA01130-102_3/old.bin", "old")
	_write(ps4_games + "/CUSA22222/keep.bin", "keep")
	_write(ps4_games + "/.kyodai-backup-CUSA22222-103_4/keep.bin", "keep")
	_write(ps4_games + "/.kyodai-extract-104_5/keep.bin", "keep")
	_write(ps4_games + "/CUSA01130.zip", "archive")
	_write(ps4_games + "/unrelated/keep.bin", "keep")
	var ps4_cleanup: Dictionary = GameExtraction.cleanup_ps4_extracted_game(ps4_games, "CUSA01130", FSM)
	_expect(bool(ps4_cleanup.get("success", false)), "PS4 owned cleanup succeeds")
	_expect(not FSM.dir_exists(ps4_games + "/CUSA01130"), "PS4 cleanup removes incomplete owned root")
	_expect(not FSM.dir_exists(ps4_games + "/.kyodai-extract-CUSA01130-100_1") and not FSM.dir_exists(ps4_games + "/.kyodai-hoist-.kyodai-extract-CUSA01130-100_1-101_2") and not FSM.dir_exists(ps4_games + "/.kyodai-backup-CUSA01130-102_3"), "PS4 cleanup removes title-tagged operation artifacts")
	_expect(FSM.file_exists(ps4_games + "/CUSA22222/keep.bin") and FSM.file_exists(ps4_games + "/.kyodai-backup-CUSA22222-103_4/keep.bin") and FSM.file_exists(ps4_games + "/.kyodai-extract-104_5/keep.bin") and FSM.file_exists(ps4_games + "/CUSA01130.zip") and FSM.file_exists(ps4_games + "/unrelated/keep.bin"), "PS4 cleanup preserves other games, anonymous artifacts, archive, and unrelated files")
	_write(ps4_games + "/CUSA01130/partial.bin", "partial")
	ps4_cleanup = GameExtraction.cleanup_ps4_extracted_game(ps4_games, "../CUSA01130", FSM)
	_expect(not bool(ps4_cleanup.get("success", true)) and FSM.file_exists(ps4_games + "/CUSA01130/partial.bin"), "PS4 invalid cleanup identity leaves owned root untouched")

	var xbox_staged := _temp_root + "/xbox_staged"
	var xbox_live := _temp_root + "/xbox_live"
	_write(xbox_staged + "/outer/content/default.xex", "xex")
	_write(xbox_live + "/stale.bin", "stale")
	commit = FSM.replace_extraction_payload(xbox_staged, xbox_live)
	_expect_status("xbox preserve-layout replacement", commit, "replaced")
	_expect(FSM.file_exists(xbox_live + "/outer/content/default.xex"), "xbox internal wrappers preserved")
	_expect(not FSM.file_exists(xbox_live + "/stale.bin"), "replacement removes stale game files")
	_expect(not FSM.dir_exists(xbox_staged), "replacement consumes source root")

	var backup_staged := _temp_root + "/backup_staged"
	var backup_live := _temp_root + "/backup_live"
	_write(backup_staged + "/new.bin", "new")
	_write(backup_live + "/old.bin", "old")
	commit = FSM.replace_extraction_payload(backup_staged, backup_live, true)
	_expect_status("replacement retains requested backup", commit, "replaced")
	_expect(str(commit.get("backup_path", "")) != "" and FSM.file_exists(str(commit.get("backup_path", "")) + "/old.bin"), "rollback backup retained on request")
	_expect(str(commit.get("backup_path", "")).get_file().begins_with(".kyodai-backup-"), "rollback backup hidden from library scans")
	FSM.delete_dir_recursive(str(commit.get("backup_path", "")))

	var named_save_staged := _temp_root + "/named_save_staged"
	var named_save_live := _temp_root + "/named_save_live"
	_write(named_save_staged + "/wrapper/PCSE00965/save.dat", "save")
	var named_layout := SaveLayout.policy("vita3k", "psvita")
	named_layout["archive_root"] = "PCSE00965"
	named_layout["commit_root"] = named_save_live
	var restored: Dictionary = SaveLayout.restore_staged_save(named_save_staged, named_layout, FSM)
	_expect(restored.get("success", false), "named-root save restores successfully")
	_expect(FSM.file_exists(named_save_live + "/save.dat"), "named-root save commits direct payload; root=" + str(FSM.list_dir(named_save_live)) + " restored=" + str(restored))

	var bare_save_staged := _temp_root + "/bare_save_staged"
	var bare_save_live := _temp_root + "/bare_save_live"
	_write(bare_save_staged + "/save.dat", "new")
	_write(bare_save_live + "/stale.dat", "stale")
	var bare_layout := SaveLayout.policy("pcsx2", "ps2")
	bare_layout["commit_root"] = bare_save_live
	restored = SaveLayout.restore_staged_save(bare_save_staged, bare_layout, FSM)
	_expect(restored.get("success", false), "bare save replacement succeeds")
	_expect(FSM.file_exists(bare_save_live + "/save.dat") and not FSM.file_exists(bare_save_live + "/stale.dat"), "bare save replacement removes stale content")

	var card_staged := _temp_root + "/card_staged"
	var card_live := _temp_root + "/card_live"
	_write(card_staged + "/game.gci", "game")
	_write(card_live + "/other.gci", "other")
	var card_layout := SaveLayout.policy("dolphin", "ngc")
	card_layout["commit_root"] = card_live
	restored = SaveLayout.restore_staged_save(card_staged, card_layout, FSM)
	_expect(restored.get("success", false), "shared card save merge succeeds")
	_expect(FSM.file_exists(card_live + "/game.gci") and FSM.file_exists(card_live + "/other.gci"), "shared card merge preserves other games")

	var psp_staged := _temp_root + "/psp_staged"
	var psp_live := _temp_root + "/psp_live"
	_write(psp_staged + "/outer/ULUS12345A/save.dat", "a")
	_write(psp_staged + "/outer/ULUS12345B/other.dat", "b")
	_write(psp_staged + "/outer/UNRELATED/skip.dat", "skip")
	_write(psp_live + "/ULUS12345A/stale.dat", "stale")
	_write(psp_live + "/UNRELATED/keep.dat", "keep")
	var psp_layout := SaveLayout.policy("ppsspp", "psp")
	psp_layout["archive_root"] = "ULUS12345"
	psp_layout["commit_root"] = psp_live
	restored = SaveLayout.restore_staged_save(psp_staged, psp_layout, FSM)
	_expect(restored.get("success", false), "PSP component restore succeeds")
	_expect(FSM.file_exists(psp_live + "/ULUS12345A/save.dat") and FSM.file_exists(psp_live + "/ULUS12345B/other.dat"), "PSP restores all matching components")
	_expect(not FSM.file_exists(psp_live + "/ULUS12345A/stale.dat"), "PSP component replacement removes stale content")
	_expect(FSM.file_exists(psp_live + "/UNRELATED/keep.dat"), "PSP restore preserves unrelated saves")

	var empty_staged := _temp_root + "/empty_save_staged"
	FSM.make_dir_recursive(empty_staged)
	restored = SaveLayout.restore_staged_save(empty_staged, bare_layout, FSM)
	_expect(not restored.get("success", true), "empty save payload rejected")

	var rpcs3_staged := _temp_root + "/rpcs3_staged"
	var rpcs3_live := _temp_root + "/rpcs3_live"
	_write(rpcs3_staged + "/wrapper/BLUS30721-BCSAVEDATA/save.dat", "save")
	var rpcs3_layout := SaveLayout.policy("rpcs3", "ps3")
	rpcs3_layout["root_prefix"] = true
	rpcs3_layout["archive_root"] = "BLUS30721"
	rpcs3_layout["extract_dest"] = rpcs3_live
	rpcs3_layout["commit_root"] = rpcs3_live + "/BLUS30721"
	restored = SaveLayout.restore_staged_save(rpcs3_staged, rpcs3_layout, FSM)
	_expect(restored.get("success", false), "RPCS3 suffixed root restores successfully")
	_expect(FSM.file_exists(rpcs3_live + "/BLUS30721-BCSAVEDATA/save.dat"), "RPCS3 actual suffixed root committed")
	_expect(str(rpcs3_layout.get("boundary_path", "")) == rpcs3_live + "/BLUS30721-BCSAVEDATA", "RPCS3 boundary follows actual save root")

	var empty_named_staged := _temp_root + "/empty_named_staged"
	var empty_named_live := _temp_root + "/empty_named_live"
	FSM.make_dir_recursive(empty_named_staged + "/PCSE00965")
	_write(empty_named_staged + "/unrelated/file.dat", "unrelated")
	_write(empty_named_live + "/old.dat", "old")
	named_layout["commit_root"] = empty_named_live
	restored = SaveLayout.restore_staged_save(empty_named_staged, named_layout, FSM)
	_expect(not restored.get("success", true), "empty named root rejected")
	_expect(FSM.file_exists(empty_named_live + "/old.dat"), "empty named root cannot replace live save")

	var empty_component_staged := _temp_root + "/empty_component_staged"
	var empty_component_live := _temp_root + "/empty_component_live"
	_write(empty_component_staged + "/ULUS12345A/save.dat", "new")
	FSM.make_dir_recursive(empty_component_staged + "/ULUS12345B")
	_write(empty_component_live + "/ULUS12345A/old.dat", "old")
	psp_layout["commit_root"] = empty_component_live
	restored = SaveLayout.restore_staged_save(empty_component_staged, psp_layout, FSM)
	_expect(not restored.get("success", true), "empty PSP component rejected before commit")
	_expect(FSM.file_exists(empty_component_live + "/ULUS12345A/old.dat"), "empty component cannot partially replace earlier saves")

	var rollback_live := _temp_root + "/rollback_live"
	_write(rollback_live + "/save.dat", "original")
	var backup: Dictionary = FSM.create_extraction_backup(rollback_live)
	_expect(backup.get("success", false), "shared save backup created")
	_write(rollback_live + "/save.dat", "changed")
	_expect(FSM.restore_extraction_backup(str(backup.get("backup_path", "")), rollback_live), "shared save backup restores")
	_expect(_read(rollback_live + "/save.dat") == "original", "rollback restores original content")

	var new_component := _temp_root + "/new_component"
	_write(new_component + "/save.dat", "new")
	var component_rollback: Dictionary = SaveLayout._rollback_components([{"backup_path": "", "destination": new_component}], FSM)
	_expect(component_rollback.get("rollback_ok", false), "new component rollback succeeds")
	_expect(not FSM.dir_exists(new_component), "new component removed during rollback")

	var saf_staged := _temp_root + "/saf_staged"
	var saf_live := _temp_root + "/saf_live"
	_write(saf_staged + "/new.bin", "new")
	_write(saf_live + "/old.bin", "old")
	commit = FSM._replace_extraction_payload_saf(saf_staged, saf_live, false, {
		"status": "io_error", "path": saf_live, "source_path": saf_staged, "backup_path": "", "error": "",
	})
	_expect_status("copy-safe Android replacement", commit, "replaced")
	_expect(FSM.file_exists(saf_live + "/new.bin"), "copy-safe replacement installs new payload")
	_expect(not FSM.file_exists(saf_live + "/old.bin"), "copy-safe replacement removes old payload")
	_expect(str(commit.get("backup_path", "")) == "", "copy-safe replacement cleans consumed backup")

	if OS.get_name() != "Windows":
		var external := _temp_root + "/external"
		var linked := _temp_root + "/linked"
		_write(external + "/bios.bin", "external")
		FSM.make_dir_recursive(linked)
		_expect(_make_symlink(external, linked + "/wrapper"), "create symlink fixture")
		result = FSM.normalize_extraction_root(linked, ["bios.bin"])
		_expect_status("filesystem symlink payload rejected", result, "unsafe_entry")
		_expect(not FSM.file_exists(linked + "/bios.bin"), "symlink payload not moved")
		_expect(FSM.file_exists(external + "/bios.bin"), "symlink target not moved")
		_expect(FSM.extraction_tree_has_symlinks(linked), "unsafe staging can be quarantined instead of recursively cleaned")

		var linked_live_external := _temp_root + "/linked_live_external"
		var linked_live := _temp_root + "/linked_live"
		var linked_source := _temp_root + "/linked_source"
		_write(linked_live_external + "/old.bin", "old")
		for index in range(70):
			_write(linked_source + "/files/new_%02d.bin" % index, "new")
		_expect(_make_symlink(linked_live_external, linked_live), "create linked destination root")
		commit = FSM.merge_extraction_payload(linked_source, linked_live)
		_expect_status("linked destination root rejected", commit, "io_error")
		_expect(FSM.file_exists(linked_live_external + "/old.bin"), "linked destination root cannot delete external old content")
		_expect(not FSM.file_exists(linked_live_external + "/files/new_00.bin"), "linked destination root cannot install into external target")

		var ps4_link_external := _temp_root + "/ps4_link_external"
		var ps4_link_root := _temp_root + "/ps4_link_root"
		_write(ps4_link_external + "/sentinel.bin", "keep")
		FSM.make_dir_recursive(ps4_link_root)
		_expect(_make_symlink(ps4_link_external, ps4_link_root + "/CUSA01130"), "create PS4 linked owned root")
		var ps4_link_cleanup: Dictionary = GameExtraction.cleanup_ps4_extracted_game(ps4_link_root, "CUSA01130", FSM)
		_expect(not bool(ps4_link_cleanup.get("success", true)), "PS4 linked owned root cleanup rejected")
		_expect(FSM.file_exists(ps4_link_external + "/sentinel.bin"), "PS4 linked cleanup cannot delete external target")

		var listing_source := _temp_root + "/listing_source"
		var listing_live := _temp_root + "/listing_live"
		for index in range(70):
			_write(listing_source + "/files/new_%02d.bin" % index, "new")
		_write(listing_source + "/protected/new.bin", "new")
		_write(listing_live + "/protected/old.bin", "old")
		var protected_dir := ProjectSettings.globalize_path(listing_live + "/protected")
		_expect(OS.execute("chmod", ["000", protected_dir], [], true) == 0, "make old payload directory unreadable")
		var listing_result: Dictionary = FSM._try_swap_extraction_merge(listing_source, listing_live)
		_expect(OS.execute("chmod", ["700", protected_dir], [], true) == 0, "restore old payload directory permissions")
		_expect(not bool(listing_result.get("success", true)), "listing failure aborts swap instead of treating old directory as empty")
		_expect(FSM.file_exists(listing_live + "/protected/old.bin"), "listing failure rollback restores unreadable old content")
		_expect(not FSM.file_exists(listing_live + "/protected/new.bin"), "listing failure does not leave new content in live")
		_expect(FSM.file_exists(listing_source + "/protected/new.bin"), "listing failure preserves staged new content")

		var recovery_source := _temp_root + "/recovery_source"
		var recovery_dest := _temp_root + "/recovery_dest"
		var recovery_backup := _temp_root + "/recovery_backup"
		_write(recovery_dest + "/new.bin", "new")
		_write(recovery_dest + "/profiles/old.ini", "old")
		_write(recovery_backup + "/Dolphin.exe", "old executable")
		FSM.make_dir_recursive(recovery_backup + "/profiles")
		var recovery_moves: Array[String] = ["profiles/old.ini", "profiles/missing.bin"]
		var partial_rollback: Dictionary = FSM._rollback_swap_extraction_merge(recovery_source, recovery_dest, recovery_backup, recovery_moves)
		_expect(not bool(partial_rollback.get("success", true)), "partial rollback failure is reported")
		_expect(FSM.file_exists(recovery_dest + "/profiles/old.ini") and FSM.file_exists(recovery_dest + "/Dolphin.exe"), "rollback continues restoring other old entries after a failure")
		_expect(FSM.file_exists(recovery_source + "/new.bin") and not FSM.file_exists(recovery_source + "/profiles/old.ini"), "partial rollback preserves remaining mixed source tree")
		var recovery_path: String = FSM._preserve_extraction_recovery_source(recovery_source)
		_expect(recovery_path != "" and FSM.file_exists(recovery_path + "/new.bin") and not FSM.dir_exists(recovery_source), "mixed recovery tree moves outside normal staging cleanup")

func _run_3ds_tests() -> void:
	var root := _temp_root + "/3ds"
	var data := root + "/title/data"
	var extdata := root + "/identity/extdata/00000000/00000001"
	_write(data + "/old.bin", "old data")
	_write(extdata + "/old.bin", "old extdata")
	FSM.make_dir_recursive(data + "/old_empty")
	FSM.make_dir_recursive(extdata + "/old_empty")
	var both_zip := root + "/both.zip"
	_make_test_zip(both_zip, ["data/new.bin", "data/replay_/", "extdata/new.bin", "extdata/empty_/"])
	_expect(SaveLayout.unpack_3ds_archive(both_zip, data, extdata, FSM), "3DS two-component restore succeeds")
	_expect(FSM.file_exists(data + "/new.bin") and FSM.file_exists(extdata + "/new.bin"), "3DS two-component restore installs both payloads")
	_expect(not FSM.file_exists(data + "/old.bin") and not FSM.file_exists(extdata + "/old.bin"), "3DS replacement removes stale component content")
	_expect(FSM.dir_exists(data + "/replay_"), "3DS restore preserves data empty directory")
	_expect(FSM.dir_exists(extdata + "/empty_"), "3DS restore preserves extdata empty directory")
	_expect(not FSM.dir_exists(data + "/old_empty") and not FSM.dir_exists(extdata + "/old_empty"), "3DS replacement removes old empty directories in replaced components")

	_write(extdata + "/keep.bin", "keep")
	FSM.make_dir_recursive(extdata + "/keep_empty")
	var data_only_zip := root + "/data_only.zip"
	_make_test_zip(data_only_zip, ["data/data_only.bin"])
	_expect(SaveLayout.unpack_3ds_archive(data_only_zip, data, extdata, FSM), "3DS data-only restore succeeds")
	_expect(FSM.file_exists(data + "/data_only.bin") and FSM.file_exists(extdata + "/keep.bin") and FSM.dir_exists(extdata + "/keep_empty"), "3DS data-only restore preserves extdata and empty directories")

	_write(data + "/keep.bin", "keep")
	FSM.make_dir_recursive(data + "/keep_empty")
	var ext_only_zip := root + "/ext_only.zip"
	_make_test_zip(ext_only_zip, ["extdata/ext_only.bin"])
	_expect(SaveLayout.unpack_3ds_archive(ext_only_zip, data, extdata, FSM), "3DS extdata-only restore succeeds")
	_expect(FSM.file_exists(extdata + "/ext_only.bin") and FSM.file_exists(data + "/keep.bin") and FSM.dir_exists(data + "/keep_empty"), "3DS extdata-only restore preserves data and empty directories")

	var empty_zip := root + "/empty.zip"
	_make_test_zip(empty_zip, [])
	_expect(not SaveLayout.unpack_3ds_archive(empty_zip, data, extdata, FSM), "3DS empty archive rejected")
	_expect(FSM.file_exists(data + "/keep.bin") and FSM.file_exists(extdata + "/ext_only.bin"), "3DS empty archive leaves live components intact")
	var unknown_zip := root + "/unknown.zip"
	_make_test_zip(unknown_zip, ["other/file.bin"])
	_expect(not SaveLayout.unpack_3ds_archive(unknown_zip, data, extdata, FSM), "3DS unknown root rejected")
	var traversal_zip := root + "/traversal.zip"
	_make_test_zip(traversal_zip, ["data/../../escape.bin"])
	_expect(not SaveLayout.unpack_3ds_archive(traversal_zip, data, extdata, FSM), "3DS traversal entry rejected")
	_expect(not FSM.file_exists(root + "/escape.bin"), "3DS traversal cannot escape operation root")
	var duplicate_zip := root + "/duplicate.zip"
	_make_test_zip(duplicate_zip, ["data/same.bin", "data/same.bin"])
	_expect(not SaveLayout.unpack_3ds_archive(duplicate_zip, data, extdata, FSM), "3DS duplicate destination rejected")
	_expect(FSM.file_exists(data + "/keep.bin") and FSM.file_exists(extdata + "/ext_only.bin"), "3DS invalid archives leave live components intact")

	# A read-only title parent prevents the staging root from being created. No
	# live replacement or backup phase may begin.
	var title_parent := ProjectSettings.globalize_path(root + "/title")
	_expect(OS.execute("chmod", ["500", title_parent], [], true) == 0, "make 3DS staging parent read-only")
	_expect(not SaveLayout.unpack_3ds_archive(data_only_zip, data, extdata, FSM), "3DS staging failure aborts before live mutation")
	_expect(OS.execute("chmod", ["700", title_parent], [], true) == 0, "restore 3DS staging parent permissions")
	_expect(FSM.file_exists(data + "/keep.bin") and FSM.file_exists(extdata + "/ext_only.bin"), "3DS staging failure preserves live components")

	# Fail the second component's backup rename. The first component must be
	# restored by the outer transaction and the second must remain untouched.
	var tx_data := root + "/tx_data/data"
	var tx_ext := root + "/tx_ext/extdata"
	var tx_data_stage := root + "/tx_data/data_stage"
	var tx_ext_stage := root + "/tx_ext/ext_stage"
	_write(tx_data + "/old.bin", "old data")
	_write(tx_ext + "/old.bin", "old extdata")
	FSM.make_dir_recursive(tx_data + "/old_empty")
	FSM.make_dir_recursive(tx_ext + "/old_empty")
	_write(tx_data_stage + "/new.bin", "new data")
	_write(tx_ext_stage + "/new.bin", "new extdata")
	var tx_parent := ProjectSettings.globalize_path(root + "/tx_ext")
	_expect(OS.execute("chmod", ["500", tx_parent], [], true) == 0, "make second 3DS destination parent read-only")
	var transaction: Dictionary = SaveLayout.replace_components_transaction([
		{"source": tx_data_stage, "destination": tx_data},
		{"source": tx_ext_stage, "destination": tx_ext},
	], FSM)
	_expect(OS.execute("chmod", ["700", tx_parent], [], true) == 0, "restore second 3DS destination parent permissions")
	_expect(not bool(transaction.get("success", true)), "3DS second component failure reported")
	_expect(_read(tx_data + "/old.bin") == "old data" and _read(tx_ext + "/old.bin") == "old extdata", "3DS transaction rolls back both old components")
	_expect(FSM.dir_exists(tx_data + "/old_empty") and FSM.dir_exists(tx_ext + "/old_empty"), "3DS rollback preserves old empty directories")
	_expect(not FSM.file_exists(tx_data + "/new.bin") and not FSM.file_exists(tx_ext + "/new.bin"), "3DS rollback removes newly written component content")

func _run_content_hash_tests() -> void:
	var root := _temp_root + "/hashes"
	_write(root + "/plain.bin", "abc")
	_expect(ContentHash.compute_content_hash(root + "/plain.bin") == "900150983cd24fb0d6963f7d28e17f72", "RomM plain-file content hash matches raw MD5")
	_write(root + "/plain.bin", "abd")
	_expect(ContentHash.compute_content_hash(root + "/plain.bin") != "900150983cd24fb0d6963f7d28e17f72", "RomM content hash detects changed bytes")

	var zip_path := root + "/entries.zip"
	var writer := ZIPPacker.new()
	_expect(writer.open(zip_path, ZIPPacker.APPEND_CREATE) == OK, "create hash verification ZIP")
	writer.start_file("data/a.bin")
	writer.write_file("new".to_utf8_buffer())
	writer.start_file("data/empty.bin")
	writer.write_file(PackedByteArray())
	writer.close()
	var expected_lines: Array[String] = [
		"data/a.bin:" + ContentHash._md5_bytes("new".to_utf8_buffer()),
		"data/empty.bin:" + ContentHash._md5_bytes(PackedByteArray()),
	]
	expected_lines.sort()
	var expected_zip: String = ContentHash._md5_bytes("\n".join(expected_lines).to_utf8_buffer())
	_expect(ContentHash.compute_content_hash(zip_path) == expected_zip, "RomM ZIP hash includes zero-length entries")
	_expect(ContentHash.compute_content_hash(zip_path) == ContentHash.compute_zip_hash(zip_path), "content_hash auto-detects ZIP by magic")

	_write(root + "/folder/a.bin", "new")
	_write(root + "/folder/empty.bin", "")
	var folder_hash: String = ContentHash.compute_folder_zip_hash(root + "/folder")
	var folder_zip := root + "/folder.zip"
	_expect(FSM.zip_directory(root + "/folder", folder_zip), "pack folder for hash parity check")
	_expect(folder_hash == ContentHash.compute_zip_hash(folder_zip), "folder simulation and real ZIP hash agree with empty files")

func _run_lifecycle_tests() -> void:
	if FSM.dir_exists("user://temp/operations"):
		FSM.delete_dir_recursive("user://temp/operations")
	var destination := _temp_root + "/locked_destination"
	var first := OperationLifecycle.acquire(destination, "extracting")
	_expect(not first.is_empty(), "destination lock acquired")
	_expect(OperationLifecycle.is_locked(destination), "destination reports locked while owned")
	var competing := OperationLifecycle.acquire(destination, "commit_started")
	_expect(competing.is_empty(), "independent same-process operation cannot claim owned destination")
	var nested := OperationLifecycle.acquire(destination, "commit_started", 0, [], first)
	_expect(not nested.is_empty() and bool(nested.get("nested", false)), "explicit parent token permits nested destination commit")
	OperationLifecycle.release(nested)
	var lock_dir := str(first.get("lock_dir", ""))
	_expect(DirAccess.dir_exists_absolute(lock_dir), "atomic lock directory exists")
	_expect(DirAccess.make_dir_absolute(lock_dir) != OK, "atomic lock directory cannot be claimed twice")
	OperationLifecycle.update_phase(first, "commit_started")
	var owner := OperationLifecycle.read_owner(lock_dir)
	_expect(int(owner.get("pid", 0)) == OS.get_process_id() and str(owner.get("phase", "")) == "commit_started", "lock owner records process and phase")
	OperationLifecycle.release(first)
	_expect(not DirAccess.dir_exists_absolute(lock_dir), "lock release removes owner directory")
	_expect(not OperationLifecycle.is_locked(destination), "destination reports unlocked after release")

	var live_artifact := "user://temp/saves/live_operation"
	_write(live_artifact + "/payload.bin", "live")
	var live_lock := OperationLifecycle.acquire(destination, "extracting", 0, [live_artifact])
	OperationLifecycle.cleanup_stale_operations(0)
	_expect(FSM.file_exists(live_artifact + "/payload.bin"), "cleanup preserves artifact with live owner")
	OperationLifecycle.release(live_lock)
	FSM.delete_dir_recursive(live_artifact)

	var stale_artifact := "user://temp/saves/stale_operation"
	_write(stale_artifact + "/payload.bin", "stale")
	var stale_lock := OperationLifecycle.acquire(destination, "extracting", 0, [stale_artifact])
	var stale_owner := OperationLifecycle.read_owner(str(stale_lock.get("lock_dir", "")))
	stale_owner["pid"] = 99999999
	stale_owner["heartbeat"] = 0
	OperationLifecycle._write_owner(str(stale_lock.get("lock_dir", "")), stale_owner)
	OperationLifecycle.cleanup_stale_operations(0)
	_expect(not FSM.file_exists(stale_artifact + "/payload.bin"), "dead pre-commit owner artifact reclaimed")
	OperationLifecycle.release(stale_lock)

	var acquire_stale_artifact := "user://temp/saves/acquire_stale_operation"
	_write(acquire_stale_artifact + "/payload.bin", "stale")
	var acquire_stale_lock := OperationLifecycle.acquire(destination, "extracting", 0, [acquire_stale_artifact])
	var acquire_stale_owner := OperationLifecycle.read_owner(str(acquire_stale_lock.get("lock_dir", "")))
	acquire_stale_owner["pid"] = 99999999
	acquire_stale_owner["heartbeat"] = 0
	OperationLifecycle._write_owner(str(acquire_stale_lock.get("lock_dir", "")), acquire_stale_owner)
	OperationLifecycle._held.clear() # Simulate restart with only the stale on-disk lock.
	var replacement_lock := OperationLifecycle.acquire(destination, "extracting")
	_expect(not replacement_lock.is_empty() and not FSM.file_exists(acquire_stale_artifact + "/payload.bin"), "acquire reclaims dead pre-commit owner and artifact")
	OperationLifecycle.release(replacement_lock)
	OperationLifecycle.release(acquire_stale_lock)

	var recovery_artifact := "user://temp/saves/recovery_operation"
	_write(recovery_artifact + "/old.bin", "old")
	var recovery_lock := OperationLifecycle.acquire(destination, "commit_started", 0, [recovery_artifact])
	var recovery_owner := OperationLifecycle.read_owner(str(recovery_lock.get("lock_dir", "")))
	recovery_owner["pid"] = 99999999
	recovery_owner["heartbeat"] = 0
	OperationLifecycle._write_owner(str(recovery_lock.get("lock_dir", "")), recovery_owner)
	OperationLifecycle.cleanup_stale_operations(0)
	_expect(FSM.file_exists(recovery_artifact + "/old.bin"), "dead commit-started recovery artifact preserved")
	OperationLifecycle.release(recovery_lock)
	FSM.delete_dir_recursive(recovery_artifact)

	var preserved_artifact := "user://temp/saves/preserved_recovery"
	_write(preserved_artifact + "/old.bin", "old")
	var preserve_lock := OperationLifecycle.acquire(destination, "commit_started", 0, [preserved_artifact])
	OperationLifecycle.preserve_recovery(preserve_lock, preserved_artifact)
	OperationLifecycle.release(preserve_lock)
	var quarantined := OperationLifecycle._child_dirs(OperationLifecycle.QUARANTINE_ROOT)
	var rollback_manifest := false
	for quarantine in quarantined:
		rollback_manifest = rollback_manifest or str(OperationLifecycle.read_owner(quarantine).get("phase", "")) == "rollback_failed"
	_expect(rollback_manifest, "release quarantines rollback recovery manifest")
	_expect(FSM.file_exists(preserved_artifact + "/old.bin"), "release preserves rollback recovery artifact")
	FSM.delete_dir_recursive(preserved_artifact)

	var empty_lock := OperationLifecycle.LOCK_ROOT + "/empty.lock"
	DirAccess.make_dir_recursive_absolute(empty_lock)
	_expect(OS.execute("touch", ["-d", "2000-01-01", ProjectSettings.globalize_path(empty_lock)], [], true) == 0, "age empty lock directory")
	OperationLifecycle.cleanup_stale_operations(0)
	_expect(not DirAccess.dir_exists_absolute(empty_lock), "aged ownerless lock directory reclaimed")

	var untracked := "user://temp/saves/.kyodai-extract-old"
	_write(untracked + "/old.bin", "old")
	_expect(OS.execute("touch", ["-d", "2000-01-01", ProjectSettings.globalize_path(untracked)], [], true) == 0, "age untracked operation directory")
	_write("user://temp/saves/download_old.zip", "old")
	_expect(OS.execute("touch", ["-d", "2000-01-01", ProjectSettings.globalize_path("user://temp/saves/download_old.zip")], [], true) == 0, "age abandoned download file")
	OperationLifecycle.cleanup_stale_untracked(["user://temp/saves"], 0)
	_expect(not FSM.dir_exists(untracked), "aged untracked operation directory reclaimed")
	_expect(not FSM.file_exists("user://temp/saves/download_old.zip"), "aged abandoned download file reclaimed")
	if FSM.dir_exists("user://temp/operations"):
		FSM.delete_dir_recursive("user://temp/operations")

func _expect_plan(name: String, entries: Array, options: Dictionary, expected_status: String, expected_root = null) -> void:
	var result := Layout.plan(entries, options)
	_expect(str(result.get("status", "")) == expected_status, "%s: expected %s, got %s (%s)" % [name, expected_status, result.get("status", ""), result.get("error", "")])
	if expected_root != null:
		_expect(str(result.get("payload_root", "")) == str(expected_root), name + ": payload root")

func _expect_status(name: String, result: Dictionary, expected: String) -> void:
	_expect(str(result.get("status", "")) == expected, "%s: expected %s, got %s (%s)" % [name, expected, result.get("status", ""), result.get("error", "")])

func _expect(condition: bool, name: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		printerr("[extraction-layout] FAIL: " + name)

func _make_test_zip(path: String, entries: Array) -> void:
	FSM.make_dir_recursive(path.get_base_dir())
	var writer := ZIPPacker.new()
	_expect(writer.open(path, ZIPPacker.APPEND_CREATE) == OK, "create 3DS test archive: " + path)
	for entry in entries:
		_expect(writer.start_file(entry) == OK, "start 3DS test ZIP entry: " + entry)
		if not str(entry).ends_with("/"):
			writer.write_file("new".to_utf8_buffer())
	writer.close()

func _write(path: String, content: String) -> void:
	FSM.make_dir_recursive(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_expect(false, "create fixture: " + path)
		return
	file.store_string(content)
	file.close()

func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var content := file.get_as_text()
	file.close()
	return content

## Godot normalizes backslashes in FileAccess paths on Unix, so create this one
## fixture through the literal filesystem interface used by real ZIP extraction.
func _write_literal(path: String, content: String) -> bool:
	FSM.make_dir_recursive(path.get_base_dir())
	var absolute_path := ProjectSettings.globalize_path(path)
	var command := "printf %s " + _shell_quote(content) + " > " + _shell_quote(absolute_path)
	return OS.execute("/bin/sh", ["-c", command], [], true) == 0

func _shell_quote(value: String) -> String:
	return "'" + value.replace("'", "'\\''") + "'"

func _make_symlink(target: String, link_path: String) -> bool:
	var absolute_target := ProjectSettings.globalize_path(target)
	var absolute_link := ProjectSettings.globalize_path(link_path)
	var command := "ln -s " + _shell_quote(absolute_target) + " " + _shell_quote(absolute_link)
	return OS.execute("/bin/sh", ["-c", command], [], true) == 0
