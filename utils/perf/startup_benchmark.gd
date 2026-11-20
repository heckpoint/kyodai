class_name StartupBenchmark
extends RefCounted

## Headless startup/shutdown benchmark harness. Extracted from main.gd so the
## boot script stays lifecycle-only. Driven by command-line flags:
##   --benchmark-startup[-delay=<sec>]   run startup, optional timed scenarios
##   --benchmark-staggered[-at=<sec>]    flip staggered layout (immediately or timed)
##   --benchmark-paginated[-at=<sec>]    flip pagination (immediately or timed)
##   --benchmark-scroll-to=<idx>[,back]  force a recycle burst mid-run
##   --benchmark-shutdown                trigger the close notification after startup

## Inspect the args and run the requested benchmark mode, if any.
## Returns true when a benchmark was triggered (the caller should skip the rest
## of startup epilogue in the startup-benchmark case).
static func run_from_args(host: Node) -> bool:
	var args := OS.get_cmdline_args()
	var startup_benchmark := args.has("--benchmark-startup")
	var shutdown_benchmark := args.has("--benchmark-shutdown")

	# If the startup benchmark flag is set, log startup and exit through the close
	# handler so we get a clean shutdown and no leaked background threads.
	if startup_benchmark:
		var delay_sec := 0.0
		for arg in args:
			if arg.begins_with("--benchmark-startup-delay="):
				delay_sec = arg.split("=")[1].to_float()
		print("[Main] --benchmark-startup: startup complete, shutdown in ", delay_sec, "s")
		if delay_sec > 0.0:
			# --benchmark-staggered-at=<sec>: enable staggered AFTER startup has
			# settled (mirrors a live menu toggle); bare --benchmark-staggered
			# enables immediately. Same for --benchmark-paginated(-at).
			var staggered_at := -1.0
			var paginated_at := -1.0
			for arg in args:
				if arg.begins_with("--benchmark-staggered-at="):
					staggered_at = arg.split("=")[1].to_float()
				if arg.begins_with("--benchmark-paginated-at="):
					paginated_at = arg.split("=")[1].to_float()
			if args.has("--benchmark-staggered"):
				staggered_at = 0.0
			if args.has("--benchmark-paginated"):
				paginated_at = 0.0
			if staggered_at >= 0.0:
				_set_state_delayed(host, staggered_at, "staggered")
			if paginated_at >= 0.0:
				_set_state_delayed(host, paginated_at, "paginated")
			# --benchmark-scroll-to=<idx>[,back]: force a recycle burst by
			# jumping to an index mid-run ("back" returns to 0 before the dump).
			var scroll_to := -1
			var scroll_back := false
			for arg in args:
				if arg.begins_with("--benchmark-scroll-to="):
					var spec = arg.split("=")[1]
					scroll_to = spec.split(",")[0].to_int()
					scroll_back = spec.contains("back")
			if scroll_to >= 0:
				_scroll_sequence(host, minf(delay_sec - 1.5, 2.5), scroll_to, scroll_back)
			await host.get_tree().create_timer(delay_sec).timeout
			dump_grid_debug_state()
		shutdown.call_deferred(host)
		return true

	# If the shutdown benchmark flag is set, trigger the close notification after
	# startup so we can measure shutdown time in an automated way.
	if shutdown_benchmark:
		shutdown.call_deferred(host)
		return true

	return false

static func shutdown(host: Node) -> void:
	"""Trigger the close notification so we can measure shutdown time automatically."""
	print("[Main] --benchmark-shutdown: triggering close notification")
	host.get_tree().root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)

static func _set_state_delayed(host: Node, at_sec: float, what: String) -> void:
	"""Benchmark helper: flip a layout flag via the shared runtime state after a
	delay (no persistence), mirroring a post-settle menu toggle."""
	await host.get_tree().create_timer(at_sec).timeout
	if not UIManager or not UIManager.card_settings_state:
		return
	if what == "staggered":
		UIManager.card_settings_state.set_grid_staggered(true)
	else:
		UIManager.card_settings_state.set_pagination_enabled(true)
	print("[Main] benchmark: enabled ", what, " at ", at_sec, "s")

static func _scroll_sequence(host: Node, at_sec: float, idx: int, and_back: bool) -> void:
	"""Benchmark helper: raw scroll to force card recycling, optionally back.
	idx is interpreted as a pixel-ish target via index->slot scroll math."""
	await host.get_tree().create_timer(maxf(at_sec, 0.1)).timeout
	var home_view = UIManager.get_view("Home") if UIManager else null
	if not home_view or not home_view.games_grid:
		return
	var grid = home_view.games_grid
	var target = grid.get_centered_scroll_for_index(idx)
	print("[Main] benchmark: raw scroll to ", target, " (idx ", idx, ")")
	grid._scroll_container.scroll_vertical = int(target)
	grid._on_scroll_value_changed(target, true, true)
	if and_back:
		await host.get_tree().create_timer(0.75).timeout
		if not is_instance_valid(grid):
			return
		print("[Main] benchmark: scroll back to 0")
		grid._scroll_container.scroll_vertical = 0
		grid._on_scroll_value_changed(0.0, true, true)

static func dump_grid_debug_state() -> void:
	"""Benchmark diagnostic: dump the Home grid's layout state after startup."""
	var home_view = UIManager.get_view("Home") if UIManager else null
	if not home_view or not home_view.games_grid:
		print("[GridDump] no home grid")
		return
	var grid = home_view.games_grid
	var info = grid.get_visible_range()
	print("[GridDump] ipl=", grid._get_items_per_line(), " card_size=", grid.card_size, " source_total=", info.get("source_total", -1), " total=", info.get("total", -1), " staggered=", grid.staggered, " last_staggered=", grid._last_layout_staggered, " paginated=", grid.pagination_enabled)
	var flow = grid._flow_container
	print("[GridDump] flow min_size=", flow.custom_minimum_size, " size=", flow.size, " children=", flow.get_child_count(), " active=", grid._active_cards.size())
	var xs: Array = []
	for i in range(mini(14, flow.get_child_count())):
		var c = flow.get_child(i)
		var tag := "SP" if (c.has_meta("page_spacer") or c.has_meta("stagger_spacer")) else str(c.get_meta("virtual_index", -1))
		xs.append("%s@(%d,%d)" % [tag, int(c.position.x), int(c.position.y)])
	print("[GridDump] first children=", xs)
