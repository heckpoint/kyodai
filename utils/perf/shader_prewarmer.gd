class_name ShaderPrewarmer
extends RefCounted

## Forces GPU pipeline compilation for all bundled canvas-item shaders at
## startup. Godot compiles pipelines lazily on first draw, so without this the
## first grid paint, first scroll, and the first focus each pay a compile hitch
## per shader. Every shader is drawn once into a tiny hidden SubViewport, one
## per frame so the prewarm never stalls the startup critical path.
##
## The set is tiered: everything outside shaders/background/ compiles during
## startup, plus only the background shader(s) the active config actually
## draws. Inactive backgrounds compile on demand when the user switches to
## them, so boot doesn't pay for a dozen unused pipelines.

const SCAN_DIRS := ["res://shaders", "res://addons/m3/shaders"]
const BACKGROUND_DIR := "res://shaders/background/"

## A render frame this long after kicking a compile means the compile stalled
## the render thread; idle a few frames before the next one so stalls can't
## stack onto settle/scroll/input frames.
const SLOW_RENDER_US := 16000
const BACKOFF_DIVISOR_US := 8000  # one extra idle frame per extra 8ms
const MAX_BACKOFF_FRAMES := 4
## Individual shaders that cost real time get their own log line (attribution).
const LOG_SHADER_US := 8000

# Prewarm is kicked early (autoload) with a fallback kick from Main; the
# guard makes whichever runs second a no-op.
static var _started := false

# Shutdown cancellation. prewarm() is a STATIC coroutine: unlike node-bound
# coroutines it is not aborted when an instance dies, so a frame-suspended
# prewarm can resume during tree teardown with stale viewport/rect references
# (close during prewarm = use-after-free, possibly inside the RenderingServer).
# Main's pre-shutdown cleanup calls cancel(); the coroutine bails at its next
# resume point before touching any node.
static var _cancelled := false
static var _viewport: SubViewport = null

## Called from Main's pre-shutdown cleanup so a suspended prewarm coroutine
## never touches nodes mid-teardown. Frees the hidden viewport up front so a
## resume can't force an UPDATE_ONCE draw while the RenderingServer finalizes.
static func cancel() -> void:
	_cancelled = true
	if is_instance_valid(_viewport):
		_viewport.queue_free()
	_viewport = null

## Baked shader list. The bundled set is static, so exported builds skip the
## res:// directory scan entirely; editor builds scan and validate against this
## list so adding/removing a shader is caught during development.
const BAKED_SHADER_PATHS: Array[String] = [
	"res://addons/m3/shaders/card/rounded_media.gdshader",
	"res://shaders/background/library_background_cafeos.gdshader",
	"res://shaders/background/library_background_dotgrid.gdshader",
	"res://shaders/background/library_background_gradient.gdshader",
	"res://shaders/background/library_background_gradient_flow.gdshader",
	"res://shaders/background/library_background_hero.gdshader",
	"res://shaders/background/library_background_horizon3d.gdshader",
	"res://shaders/background/library_background_isolines.gdshader",
	"res://shaders/background/library_background_motes.gdshader",
	"res://shaders/background/library_background_osdsys.gdshader",
	"res://shaders/background/library_background_xmb.gdshader",
	"res://shaders/background/library_background_xmb_classic.gdshader",
	"res://shaders/card/badge.gdshader",
	"res://shaders/card/base_card.gdshader",
	"res://shaders/card/blur.gdshader",
	"res://shaders/card/case_wrap.gdshader",
	"res://shaders/card/compositor_mask.gdshader",
	"res://shaders/card/distort.gdshader",
	"res://shaders/card/drop_shadow.gdshader",
	"res://shaders/card/glass.gdshader",
	"res://shaders/card/glass_swoop.gdshader",
	"res://shaders/card/glow.gdshader",
	"res://shaders/card/gradient_overlay.gdshader",
	"res://shaders/card/hsl.gdshader",
	"res://shaders/card/present_wrap.gdshader",
	"res://shaders/card/shine.gdshader",
	"res://shaders/card/stroke.gdshader",
	"res://shaders/focus_ring_neon.gdshader",
	"res://shaders/frosted_backdrop.gdshader",
	"res://shaders/skeleton_shimmer.gdshader",
]

static func collect_shader_paths() -> Array[String]:
	if OS.has_feature("editor"):
		# Editor: scan for real so new shaders are picked up without a list
		# edit, and warn when the baked list (used by exports) has drifted.
		var scanned := _scan_shader_paths()
		if scanned != BAKED_SHADER_PATHS:
			push_warning("[ShaderPrewarmer] BAKED_SHADER_PATHS drifted from the res:// scan; update the baked list")
		return scanned
	return BAKED_SHADER_PATHS.duplicate()

static func _scan_shader_paths() -> Array[String]:
	var paths: Array[String] = []
	for dir_path in SCAN_DIRS:
		_collect_dir(dir_path, paths)
	paths.sort()
	return paths

static func _collect_dir(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			_collect_dir(dir_path.path_join(entry), out)
		elif entry.ends_with(".gdshader"):
			out.append(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()

static func prewarm(tree: SceneTree) -> void:
	if _started or _cancelled:
		return
	_started = true
	var start_us := Time.get_ticks_usec()
	var paths := collect_shader_paths()
	if paths.is_empty():
		return
	var plan := _plan_paths(paths)
	if plan.is_empty():
		return

	var viewport := SubViewport.new()
	viewport.name = "ShaderPrewarmer"
	viewport.size = Vector2i(8, 8)
	viewport.transparent_bg = true
	viewport.gui_disable_input = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	tree.root.add_child(viewport)
	_viewport = viewport

	var compiled := 0
	for path in plan:
		# Pipeline compilation is a frame-time spike by nature; skip frames
		# where the warmup budget is already spent so compiles never stack
		# onto grid settle or scroll work, and skip frames with recent input
		# so a compile spike can't hitch an in-flight interaction.
		while not _cancelled and (not WarmupBudget.try_spend(WarmupBudget.COST_SHADER_PREWARM_US, "shader_prewarm") or WarmupBudget.input_idle_ms() < 100):
			await tree.process_frame
		# Bail before touching nodes if shutdown cancelled us or the viewport
		# was freed out from under the coroutine (root teardown).
		if _cancelled or MemorySubManager.is_shutting_down() or not is_instance_valid(viewport):
			break
		var load_start_us := Time.get_ticks_usec()
		var shader: Shader = load(path)
		var load_us := Time.get_ticks_usec() - load_start_us
		if shader == null:
			continue
		var material := ShaderMaterial.new()
		material.shader = shader
		var rect := ColorRect.new()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		rect.material = material
		viewport.add_child(rect)
		var render_start_us := Time.get_ticks_usec()
		# UPDATE_ONCE renders on the next frame, then disables again.
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await tree.process_frame
		# Same post-await bail: the frame we just waited on may have carried
		# the close notification and root teardown with it.
		if _cancelled or not is_instance_valid(viewport):
			break
		var render_us := Time.get_ticks_usec() - render_start_us
		# With threaded rendering the compile stalls the render thread and
		# surfaces a frame late; tag the render frame too so spikes attribute.
		WarmupBudget.tag("shader_rendered")
		rect.queue_free()
		compiled += 1
		if load_us > LOG_SHADER_US or render_us > LOG_SHADER_US:
			print("[ShaderPrewarmer] shader='%s' load_us=%d render_frame_us=%d" % [path.get_file(), load_us, render_us])
		# Real-cost pacing: a long render frame means this compile backed up
		# the render queue — let frames breathe before compiling the next one.
		if render_us > SLOW_RENDER_US:
			var backoff := clampi(int(render_us / float(BACKOFF_DIVISOR_US)), 1, MAX_BACKOFF_FRAMES)
			for i in backoff:
				if _cancelled:
					break
				await tree.process_frame

	if _viewport != null and is_instance_valid(_viewport):
		_viewport.queue_free()
	_viewport = null
	if _cancelled:
		print("[ShaderPrewarmer] cancelled during shutdown after %d shader pipelines, elapsed_us=%d" % [
			compiled, Time.get_ticks_usec() - start_us])
	else:
		print("[ShaderPrewarmer] compiled %d shader pipelines (skipped %d inactive backgrounds), elapsed_us=%d" % [
			compiled, paths.size() - plan.size(), Time.get_ticks_usec() - start_us])

## Startup set: active background shader(s) + everything that isn't a
## background shader. Sorted scan order puts addons/m3 first, then the active
## backgrounds (they draw from the first frame), then card/UI shaders.
static func _plan_paths(paths: Array[String]) -> Array[String]:
	var active_bg := _active_background_paths()
	var out: Array[String] = []
	for path in paths:
		if path.begins_with(BACKGROUND_DIR):
			if active_bg.has(path):
				out.append(path)
		else:
			out.append(path)
	return out

## Shader paths the active library background actually draws: each configured
## effect layer's shader.
static func _active_background_paths() -> Array[String]:
	var out: Array[String] = []
	var config: Dictionary = {}
	if DataManager:
		var setting = DataManager.get_setting("library_background_config")
		if setting and setting.value is Dictionary:
			config = setting.value
	var ids: Array[String] = []
	for entry in config.get("effects", []):
		if entry is Dictionary:
			ids.append(str(entry.get("effect_id", "")))
	for effect_id in ids:
		if effect_id.is_empty() or effect_id == "none":
			continue
		var script_path: String = LibraryBackground.EFFECT_REGISTRY.get(effect_id, "")
		if script_path.is_empty():
			# Custom effect: user://effects/background/<id>.gdshader.
			if EffectRegistry.is_custom(effect_id):
				out.append("user://effects/background/%s.gdshader" % effect_id)
			continue
		var shader_path := _preloaded_shader_path(script_path)
		if shader_path != "" and not out.has(shader_path):
			out.append(shader_path)
	return out

## Resolves the .gdshader an effect script preloads without instantiating the
## effect: tries the compiled script's constant map first (works in exported
## builds), falling back to scanning readable script source.
static func _preloaded_shader_path(script_path: String) -> String:
	var script: Script = load(script_path)
	if script != null:
		for value in script.get_script_constant_map().values():
			if value is Shader:
				var sh := value as Shader
				if sh.resource_path.ends_with(".gdshader"):
					return sh.resource_path
	var file := FileAccess.open(script_path, FileAccess.READ)
	if file == null:
		return ""
	var re := RegEx.new()
	re.compile('preload\\("(res://[^"]+\\.gdshader)"\\)')
	var hit := re.search(file.get_as_text())
	return hit.get_string(1) if hit != null else ""
