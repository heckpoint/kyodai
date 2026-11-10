@tool
class_name OobeWizard
extends M3Dialog

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

signal wizard_completed

# Page indices
enum Page {
	WELCOME,
	STORAGE_PATHS,
	ANDROID_PERMISSIONS,
	ROMM_CONNECTION,
	DONE
}

var _current_page: int = Page.WELCOME
var _pages: Array[VBoxContainer] = []

# Page content references
var _games_path_field: M3TextField
var _emulators_path_field: M3TextField
var _steam_path_field: M3TextField

var _romm_connection_panel: RommConnectionPanel

var _perm_storage_indicator: Indicator
var _perm_notifications_indicator: Indicator
var _perm_usage_indicator: Indicator
var _perm_storage_button: M3Button
var _perm_notifications_button: M3Button
var _perm_usage_button: M3Button

# Android validation
var _storage_warning_label: M3Label

func _init():
	dialog_variant = Variant.FULL_SCREEN
	dismissible = false
	persistent = true
	super._init()

func _ready():
	super._ready()

	# @tool so the dialog chrome previews in the editor, but everything below
	# builds runtime content against runtime autoloads (SystemManager,
	# DataManager) that must not run in the editor.
	if Engine.is_editor_hint():
		return

	# Hide the close button since this dialog is mandatory
	if _close_button:
		_close_button.visible = false

	# Hide default title/body — we manage title per-page
	if _title_label:
		_title_label.visible = false
	if _body_label:
		_body_label.visible = false

	# Make content slot expand
	content_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Build all pages
	_build_pages()

	# Show first page
	_show_page(Page.WELCOME)

func _build_pages():
	_pages.clear()
	_pages.append(_build_welcome_page())
	_pages.append(_build_storage_paths_page())
	_pages.append(_build_android_permissions_page())
	_pages.append(_build_romm_connection_page())
	_pages.append(_build_done_page())

func _create_placeholder_texture() -> Texture2D:
	var img := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	img.fill(Color("#1C1B1F"))
	return ImageTexture.create_from_image(img)

func _build_welcome_page() -> VBoxContainer:
	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var icon = TextureRect.new()
	icon.texture = _create_placeholder_texture()
	icon.custom_minimum_size = Vector2(M3Units.dp(128), M3Units.dp(128))
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(icon)

	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, M3Units.dp(24))
	vbox.add_child(spacer)

	var desc = M3Label.new()
	desc.text = "Let's get your emulator launcher set up.\n\nWe'll configure storage paths, permissions, and your RomM connection."
	desc.label_style = M3Label.Style.BODY_LARGE
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

	return vbox

func _build_storage_paths_page() -> VBoxContainer:
	var vbox = VBoxContainer.new()
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var desc = M3Label.new()
	desc.text = "Choose where Kyodai will store your games and emulators."
	desc.label_style = M3Label.Style.BODY_MEDIUM
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

	var sep = HSeparator.new()
	vbox.add_child(sep)

	# Games folder
	var games_default = "" if SystemManager.platform.is_android() else "user://roms/"
	_games_path_field = _add_path_row(vbox, "Games Folder", games_default)

	# Emulators folder
	var emu_default = "" if SystemManager.platform.is_android() else "user://emulators/"
	_emulators_path_field = _add_path_row(vbox, "Emulators Folder", emu_default)

	# Warning label for Android validation
	if SystemManager.platform.is_android():
		_storage_warning_label = M3Label.new()
		_storage_warning_label.text = "Please select both folders to continue"
		_storage_warning_label.label_style = M3Label.Style.BODY_SMALL
		_storage_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_storage_warning_label.visible = false
		vbox.add_child(_storage_warning_label)

	# Platform-specific paths
	if SystemManager.platform.is_windows() or SystemManager.platform.is_linux():
		_steam_path_field = _add_path_row(vbox, "Steam Installation Folder (optional)", "")

	return vbox

func _build_android_permissions_page() -> VBoxContainer:
	var vbox = VBoxContainer.new()
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	if not SystemManager.platform.is_android():
		var label = M3Label.new()
		label.text = "Permission setup is only needed on Android."
		label.label_style = M3Label.Style.BODY_LARGE
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		vbox.add_child(label)
		return vbox

	var desc = M3Label.new()
	desc.text = "Kyodai needs the following permissions to function properly."
	desc.label_style = M3Label.Style.BODY_MEDIUM
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

	vbox.add_child(HSeparator.new())

	# Storage permission
	_perm_storage_button = M3Button.new()
	_perm_storage_button.text = "Open Settings"
	_perm_storage_button.button_variant = M3Button.Variant.TONAL
	_perm_storage_button.pressed.connect(_request_storage_permission)
	var storage_row = _add_permission_row(vbox, "All Files Access", "Required to access game files on internal and SD card storage. You will be taken to system settings to enable this.", _perm_storage_button)
	_perm_storage_indicator = storage_row.indicator

	vbox.add_child(HSeparator.new())

	# Notifications
	_perm_notifications_button = M3Button.new()
	_perm_notifications_button.text = "Grant"
	_perm_notifications_button.button_variant = M3Button.Variant.TONAL
	_perm_notifications_button.pressed.connect(_request_notifications_permission)
	var notif_row = _add_permission_row(vbox, "Notifications", "Required for download progress alerts", _perm_notifications_button)
	_perm_notifications_indicator = notif_row.indicator

	vbox.add_child(HSeparator.new())

	# Usage access (optional - improves session tracking)
	_perm_usage_button = M3Button.new()
	_perm_usage_button.text = "Open Settings"
	_perm_usage_button.button_variant = M3Button.Variant.TONAL
	_perm_usage_button.pressed.connect(_open_usage_settings)
	var usage_row = _add_permission_row(vbox, "Usage Access", "Recommended: lets Kyodai detect when a game exits, so playtime is exact and saves sync the moment you stop playing. Without it, saves sync when you return to Kyodai.", _perm_usage_button)
	_perm_usage_indicator = usage_row.indicator

	return vbox

func _build_romm_connection_page() -> VBoxContainer:
	var vbox = VBoxContainer.new()
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_romm_connection_panel = RommConnectionPanel.new()
	_romm_connection_panel.show_description = true
	_romm_connection_panel.description_text = "Connect to your RomM server to browse and download games. You can skip this and configure it later in Settings."
	_romm_connection_panel.test_button_text = "Pair with RomM"
	vbox.add_child(_romm_connection_panel)

	return vbox

func _build_done_page() -> VBoxContainer:
	var vbox = VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var title = M3Label.new()
	title.text = "All Set!"
	title.label_style = M3Label.Style.HEADLINE_MEDIUM
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, M3Units.dp(12))
	vbox.add_child(spacer)

	var desc = M3Label.new()
	desc.text = "Kyodai is ready to go.\n\nYou can change any of these settings later in the Settings tab."
	desc.label_style = M3Label.Style.BODY_LARGE
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

	return vbox

func _add_path_row(parent: VBoxContainer, label_text: String, default_value: String) -> M3TextField:
	var label = M3Label.new()
	label.text = label_text
	label.label_style = M3Label.Style.BODY_MEDIUM
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)

	var container = HBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(container)

	var field = M3TextField.new()
	field.text = default_value
	field.focus_mode = Control.FOCUS_NONE
	field.virtual_keyboard_enabled = false
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(field)

	var browse = M3Button.new()
	browse.text = "Browse"
	browse.icon_name = "folder-open"
	browse.button_variant = M3Button.Variant.OUTLINED
	browse.pressed.connect(_on_browse_pressed.bind(field))
	container.add_child(browse)

	return field

func _add_permission_row(parent: VBoxContainer, title: String, description: String, action_button: M3Button = null) -> Dictionary:
	var container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(container)

	# Title row with optional button and indicator
	var title_row = HBoxContainer.new()
	title_row.custom_minimum_size = Vector2(0, M3Units.dp(36))
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(title_row)

	var title_label = M3Label.new()
	title_label.text = title
	title_label.label_style = M3Label.Style.TITLE_MEDIUM
	title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_label)

	if action_button:
		action_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		title_row.add_child(action_button)

	var indicator = Indicator.new()
	indicator.custom_minimum_size = Vector2(M3Units.dp(100), 0)
	title_row.add_child(indicator)

	# Description
	var desc_label = M3Label.new()
	desc_label.text = description
	desc_label.label_style = M3Label.Style.BODY_SMALL
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(desc_label)

	return {"container": container, "indicator": indicator}

# Navigation

func _show_page(page_idx: int):
	# Remove current page from content slot without freeing
	for child in content_slot.get_children():
		content_slot.remove_child(child)

	if page_idx >= 0 and page_idx < _pages.size():
		content_slot.add_child(_pages[page_idx])

	_current_page = page_idx

	# Update top bar title only (don't use title_text which also shows _title_label in content)
	var page_titles = {
		Page.WELCOME: "Welcome to Kyodai",
		Page.STORAGE_PATHS: "Storage Paths",
		Page.ANDROID_PERMISSIONS: "Permissions",
		Page.ROMM_CONNECTION: "RomM Connection",
		Page.DONE: "Setup Complete"
	}
	if _top_bar_title:
		_top_bar_title.text = page_titles.get(page_idx, "")

	# Update actions based on page
	_update_actions()

	# Refresh permission indicators when showing the permissions page
	if page_idx == Page.ANDROID_PERMISSIONS and SystemManager.platform.is_android():
		_update_permission_indicators()

	# Move focus to first interactive element
	call_deferred("_focus_first_element")

func _update_actions():
	clear_actions()

	match _current_page:
		Page.WELCOME:
			add_action("Next", _on_next_pressed, true)

		Page.STORAGE_PATHS:
			add_action("Back", _on_back_pressed, false)
			add_action("Next", _on_next_pressed, true)

		Page.ANDROID_PERMISSIONS:
			add_action("Back", _on_back_pressed, false)
			add_action("Next", _on_next_pressed, true)

		Page.ROMM_CONNECTION:
			add_action("Back", _on_back_pressed, false)
			add_action("Skip", _on_skip_pressed, false)
			add_action("Finish", _on_next_pressed, true)

		Page.DONE:
			add_action("Start Kyodai", _on_finish_pressed, true)

func _focus_first_element():
	match _current_page:
		Page.WELCOME:
			# Focus on the primary action button (handled by dialog)
			pass
		Page.STORAGE_PATHS:
			if _games_path_field:
				_games_path_field.grab_focus()
		Page.ANDROID_PERMISSIONS:
			if _perm_storage_button and _perm_storage_button.visible:
				_perm_storage_button.grab_focus()
		Page.ROMM_CONNECTION:
			if _romm_connection_panel:
				_romm_connection_panel.focus_url_field()
		Page.DONE:
			# Focus on finish button (handled by dialog)
			pass

func _on_back_pressed():
	if _current_page > Page.WELCOME:
		_show_page(_current_page - 1)
		# Hide warning when navigating back to storage
		if _current_page == Page.STORAGE_PATHS and _storage_warning_label:
			_storage_warning_label.visible = false

func _on_next_pressed():
	if _current_page == Page.ROMM_CONNECTION:
		# Save RomM settings if entered
		if _romm_connection_panel:
			_romm_connection_panel.save_to_settings(true)
		DataManager.save_settings()
		_show_page(Page.DONE)
	elif _current_page < Page.DONE:
		# Validate storage paths on Android before progressing
		if _current_page == Page.STORAGE_PATHS:
			if SystemManager.platform.is_android():
				if not _validate_android_storage_paths():
					if _storage_warning_label:
						_storage_warning_label.visible = true
					return
				if _storage_warning_label:
					_storage_warning_label.visible = false

			# Persist storage paths and mark first run so a restart resumes
			_save_storage_settings()
			_mark_first_run_completed()
			DataManager.save_settings()

		# Skip permissions page on non-Android
		if _current_page == Page.STORAGE_PATHS and not SystemManager.platform.is_android():
			_show_page(Page.ROMM_CONNECTION)
		else:
			_show_page(_current_page + 1)

func _validate_android_storage_paths() -> bool:
	if not SystemManager.platform.is_android():
		return true

	var games_path = _games_path_field.text.strip_edges()
	var emulators_path = _emulators_path_field.text.strip_edges()

	if games_path.is_empty() or emulators_path.is_empty():
		if _storage_warning_label:
			_storage_warning_label.text = "Please select both folders to continue"
		return false

	if games_path.begins_with("user://") or emulators_path.begins_with("user://"):
		if _storage_warning_label:
			_storage_warning_label.text = "Cannot use app private folder. Please select external storage."
		return false

	return true

func _on_skip_pressed():
	if _romm_connection_panel:
		_romm_connection_panel.save_to_settings(true)
	DataManager.save_settings()
	_show_page(Page.DONE)

func _on_finish_pressed():
	# Final flush in case anything changed on the done page (nothing to save there,
	# but this guarantees the incremental saves from earlier are on disk).
	DataManager.save_settings()

	# Mark first run as complete
	_mark_first_run_completed()
	DataManager.save_settings()

	# Dismiss and emit completed
	dismiss()
	wizard_completed.emit()

func _mark_first_run_completed():
	var first_run_setting = DataManager.get_setting("first_run_completed")
	if first_run_setting:
		DataManager.set_setting(true, first_run_setting)

# Path browsing

func _on_browse_pressed(field: M3TextField):
	UIManager.show_folder_dialog("Select Folder", field.text, func(dir: String):
		field.text = dir
	)

# Permission handling (Android)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		if _current_page == Page.ANDROID_PERMISSIONS and SystemManager.platform.is_android():
			_update_permission_indicators()

func _request_storage_permission():
	if not SystemManager.platform.is_android():
		return

	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin and plugin.hasManageExternalStoragePermission():
		return

	SystemManager.platform.open_manage_storage_settings()

func _request_notifications_permission():
	if not SystemManager.platform.is_android():
		return

	# Singular request only - OS.request_permissions() sweeps every manifest
	# permission and would open the "Install unknown apps" settings page.
	OS.request_permission("android.permission.POST_NOTIFICATIONS")

func _open_usage_settings():
	if not SystemManager.platform.is_android():
		return

	SystemManager.platform.open_usage_access_settings()

func _update_permission_indicators():
	if not SystemManager.platform.is_android():
		return

	var granted = OS.get_granted_permissions()
	var plugin = Engine.get_singleton("KyodaiBridge")

	if _perm_storage_indicator:
		var has_manage_storage = false
		if plugin:
			has_manage_storage = plugin.hasManageExternalStoragePermission()
		else:
			has_manage_storage = "android.permission.MANAGE_EXTERNAL_STORAGE" in granted
		_perm_storage_indicator.set_status(Indicator.Status.SUCCESS if has_manage_storage else Indicator.Status.ERROR, "Granted" if has_manage_storage else "Required")
		if _perm_storage_button:
			_perm_storage_button.text = "Granted" if has_manage_storage else "Open Settings"
			_perm_storage_button.disabled = has_manage_storage

	if _perm_notifications_indicator:
		var has_notif = "android.permission.POST_NOTIFICATIONS" in granted
		_perm_notifications_indicator.set_status(Indicator.Status.SUCCESS if has_notif else Indicator.Status.ERROR, "Granted" if has_notif else "Not Granted")
		if _perm_notifications_button:
			_perm_notifications_button.text = "Granted" if has_notif else "Grant"
			_perm_notifications_button.disabled = has_notif

	if _perm_usage_indicator:
		var has_usage = SystemManager.platform.has_usage_stats_permission()
		# WARNING rather than ERROR when missing: session tracking degrades
		# gracefully without this (saves sync on resume instead of on exit).
		_perm_usage_indicator.set_status(Indicator.Status.SUCCESS if has_usage else Indicator.Status.WARNING, "Granted" if has_usage else "Recommended")
		if _perm_usage_button:
			_perm_usage_button.text = "Granted" if has_usage else "Open Settings"
			_perm_usage_button.disabled = has_usage

func _save_storage_settings():
	var games_path = _games_path_field.text.strip_edges()
	var emulators_path = _emulators_path_field.text.strip_edges()

	# Resolve content:// URIs to real paths before saving
	games_path = FSM.resolve_content_uri(games_path)
	emulators_path = FSM.resolve_content_uri(emulators_path)

	if not games_path.is_empty():
		var games_setting = DataManager.get_setting("games_root_folder")
		if games_setting:
			DataManager.set_setting(games_path, games_setting)
		FSM.make_dir_recursive(games_path)

	if not emulators_path.is_empty():
		var emulators_setting = DataManager.get_setting("emulators_folder")
		if emulators_setting:
			DataManager.set_setting(emulators_path, emulators_setting)
		FSM.make_dir_recursive(emulators_path)

	if _steam_path_field and not _steam_path_field.text.is_empty():
		var steam_setting = DataManager.get_setting("steam_folder")
		if steam_setting:
			DataManager.set_setting(_steam_path_field.text, steam_setting)


# Public API

func show_page(page_idx: int):
	_show_page(page_idx)

func start_wizard():
	show_overlay()
