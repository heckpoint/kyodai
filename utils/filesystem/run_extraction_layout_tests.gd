## Headless tests for extraction-layout planning and filesystem normalization.
## Usage: utils/filesystem/run_extraction_layout_tests.sh
## The shell harness creates an isolated project; do not run this script against
## the production project because Godot would also start its real autoloads.
extends SceneTree

const Layout = preload("res://utils/filesystem/extraction_layout.gd")
const EmulatorExtraction = preload("res://utils/filesystem/emulator_extraction.gd")
const GameExtraction = preload("res://utils/filesystem/game_extraction.gd")
const SaveLayout = preload("res://utils/filesystem/save_layout.gd")

var FSM: GDScript
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
	_run_planner_tests()
	_run_emulator_registry_tests()
	_run_game_policy_tests()
	_run_save_policy_tests()
	_run_filesystem_tests()
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
	commit = FSM.merge_extraction_payload(emulator_staged, emulator_live)
	_expect_status("emulator wrapped update committed", commit, "committed")
	_expect(_read(emulator_live + "/Dolphin.exe") == "new executable", "stale live executable cannot mask wrapped update")

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
