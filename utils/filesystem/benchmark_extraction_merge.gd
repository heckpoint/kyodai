## Synthetic extraction-merge benchmark. Run through the isolated harness:
## utils/filesystem/run_extraction_layout_tests.sh benchmark_extraction_merge.gd
extends SceneTree

const FILE_COUNT_PER_DIR := 32
const DIR_COUNT := 8
const FILE_SIZE := 16 * 1024
const ITERATIONS := 5

var FSM: GDScript
var _root := ""
var _payload := PackedByteArray()

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	FSM = load("res://managers/system_manager/filesystem_sub_manager.gd")
	_root = "user://temp/extraction_merge_benchmark_" + str(Time.get_ticks_msec()) + "_" + str(randi())
	_payload.resize(FILE_SIZE)
	_payload.fill(0x5A)
	var samples: Array[float] = []
	for iteration in range(ITERATIONS):
		var staged := _root + "/staged_" + str(iteration)
		var live := _root + "/live_" + str(iteration)
		_make_staged_payload(staged)
		_make_live_payload(live)
		var started := Time.get_ticks_usec()
		var result: Dictionary = FSM.merge_extraction_payload(staged, live)
		var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
		if result.get("status", "") != "committed":
			printerr("[extraction-benchmark] commit failed: " + str(result.get("error", "")))
			quit(1)
			return
		samples.append(elapsed_ms)
		FSM.delete_dir_recursive(live)
	var total := 0.0
	for sample in samples:
		total += sample
	print("[extraction-benchmark] files=%d bytes=%d iterations=%d update_avg_ms=%.3f update_samples_ms=%s" % [
		FILE_COUNT_PER_DIR * DIR_COUNT,
		FILE_COUNT_PER_DIR * DIR_COUNT * FILE_SIZE,
		ITERATIONS,
		total / samples.size(),
		str(samples),
	])

	var fresh_samples: Array[float] = []
	for iteration in range(ITERATIONS):
		var staged := _root + "/fresh_staged_" + str(iteration)
		var live := _root + "/fresh_live_" + str(iteration)
		_make_staged_payload(staged)
		var started := Time.get_ticks_usec()
		var result: Dictionary = FSM.merge_extraction_payload(staged, live)
		var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
		if result.get("status", "") != "committed":
			printerr("[extraction-benchmark] fresh commit failed: " + str(result.get("error", "")))
			quit(1)
			return
		fresh_samples.append(elapsed_ms)
		FSM.delete_dir_recursive(live)
	total = 0.0
	for sample in fresh_samples:
		total += sample
	print("[extraction-benchmark] fresh_avg_ms=%.3f fresh_samples_ms=%s" % [total / fresh_samples.size(), str(fresh_samples)])
	FSM.delete_dir_recursive(_root)
	quit(0)

func _make_staged_payload(root: String) -> void:
	for directory in range(DIR_COUNT):
		for file_index in range(FILE_COUNT_PER_DIR):
			_write(root + "/part_%02d/file_%03d.bin" % [directory, file_index], _payload)

func _make_live_payload(root: String) -> void:
	for directory in range(DIR_COUNT):
		_write(root + "/part_%02d/keep.bin" % directory, _payload)
		# One real overwrite per directory; all other files exercise rename moves.
		_write(root + "/part_%02d/file_000.bin" % directory, _payload)

func _write(path: String, bytes: PackedByteArray) -> void:
	FSM.make_dir_recursive(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("[extraction-benchmark] could not create fixture: " + path)
		quit(1)
		return
	file.store_buffer(bytes)
	file.close()
