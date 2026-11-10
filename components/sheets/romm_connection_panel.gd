class_name RommConnectionPanel
extends VBoxContainer

signal connection_tested(success: bool)
signal connection_succeeded
signal connection_failed

@export var test_button_text: String = "Pair with RomM"
@export var test_button_variant: M3Button.Variant = M3Button.Variant.TONAL
@export var test_button_size: M3Button.Size = M3Button.Size.MEDIUM
@export var show_description: bool = true
@export var description_text: String = "Connect to your RomM server to browse and download games."
## Draw a rule under the description. Disable when the panel lives inside a
## SettingsSection card, which already provides visual separation.
@export var show_separator: bool = true

const QRCodeRectNode := preload("res://addons/kenyoni/qr_code/qr_code_rect.gd")
const QRCodeData := preload("res://addons/kenyoni/qr_code/qr_code.gd")

var _description_label: M3Label = null
var _url_field: M3TextField = null
var _username_field: M3TextField = null
var _password_field: M3TextField = null
var _http_warning_label: M3Label = null
var _http_ack_checkbox: M3Checkbox = null
var _last_eval_origin: String = ""
var _indicator: Indicator = null
var _main_button: M3Button = null

# Mode containers (visibility driven by _update_mode_visibility)
var _paired_box: VBoxContainer = null
var _connect_box: VBoxContainer = null
var _code_box: VBoxContainer = null
var _legacy_box: VBoxContainer = null
var _pairing_box: VBoxContainer = null
var _code_field: M3TextField = null
var _exchange_button: M3Button = null
var _legacy_test_button: M3Button = null
var _code_toggle: M3Button = null
var _legacy_toggle: M3Button = null

# Pairing-in-progress widgets
var _open_browser_button: M3Button = null
var _verification_complete_url: String = ""
var _verification_label: M3Label = null
var _user_code_label: M3Label = null
var _qr_rect: TextureRect = null
var _pairing_status: M3Label = null
var _cancel_pair_button: M3Button = null
var _poller: DeviceAuthPoller = null
var _pairing_base_url: String = ""

var _pairing_active := false
var _code_mode := false
var _legacy_mode := false

func _ready() -> void:
	_build_ui()
	load_from_settings()
	refresh_indicator()
	_update_http_warning()
	_update_mode_visibility()

func _exit_tree() -> void:
	_cancel_polling()

## Plain http:// sends the auth credential (and all traffic) in cleartext.
## Legitimate on a trusted LAN, so we warn instead of banning - but the user
## must explicitly acknowledge before connecting (KYD-07).
func _is_insecure_http(url: String) -> bool:
	return url.strip_edges().to_lower().begins_with("http://")

## Normalized "http://host:port" for an insecure URL ("" otherwise), matched
## against the persisted one-time acknowledgment.
func _http_origin(url: String) -> String:
	if not _is_insecure_http(url):
		return ""
	var parts: Dictionary = SystemManager.network.parse_url(url.strip_edges())
	if parts.host == "":
		return ""
	return parts.protocol.to_lower() + "://" + parts.host.to_lower() + ":" + str(parts.port)

func _update_http_warning() -> void:
	var insecure := _is_insecure_http(_url_field.text) if _url_field else false
	if _http_warning_label:
		_http_warning_label.visible = insecure
	if _http_ack_checkbox:
		_http_ack_checkbox.visible = insecure
		var origin := _http_origin(_url_field.text) if insecure else ""
		if origin == _last_eval_origin:
			return  # keep the user's manual tick stable while typing
		_last_eval_origin = origin
		# Pre-tick when this exact origin was acknowledged in a previous
		# session; a new or different http origin must be re-acknowledged.
		var ack := ""
		var ack_setting = DataManager.get_setting("romm_insecure_http_ack")
		if ack_setting:
			ack = str(ack_setting.value)
		_http_ack_checkbox.set_pressed_no_signal(origin != "" and origin == ack)

func _build_ui() -> void:
	if show_description and not description_text.is_empty():
		_description_label = M3Label.new()
		_description_label.text = description_text
		_description_label.label_style = M3Label.Style.BODY_MEDIUM
		_description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		add_child(_description_label)
		if show_separator:
			add_child(HSeparator.new())

	_url_field = M3TextField.new()
	_url_field.label_text = "RomM URL"
	_url_field.placeholder_text = "https://your-romm-server.com"
	_url_field.text_changed.connect(func(_new_text: String): _update_http_warning())
	add_child(_url_field)

	_http_warning_label = M3Label.new()
	_http_warning_label.text = "Warning: http:// sends your login token (or password) and all downloads unencrypted. Only use it on trusted local networks - use HTTPS if this server is reachable from the internet."
	_http_warning_label.label_style = M3Label.Style.BODY_SMALL
	_http_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_http_warning_label.visible = false
	add_child(_http_warning_label)

	_http_ack_checkbox = M3Checkbox.new()
	_http_ack_checkbox.text = "I understand the risk - allow insecure http://"
	_http_ack_checkbox.visible = false
	add_child(_http_ack_checkbox)

	_build_paired_box()
	_build_connect_box()
	_build_code_box()
	_build_legacy_box()
	_build_pairing_box()

	var status_row := HBoxContainer.new()
	status_row.custom_minimum_size = Vector2(0, M3Units.dp(40))
	add_child(status_row)

	_indicator = Indicator.new()
	_indicator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_indicator.set_status(Indicator.Status.NEUTRAL)
	status_row.add_child(_indicator)

func _build_paired_box() -> void:
	_paired_box = VBoxContainer.new()
	add_child(_paired_box)

	var label := M3Label.new()
	label.text = "This device is paired with your RomM account."
	label.label_style = M3Label.Style.BODY_MEDIUM
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_paired_box.add_child(label)

	var row := HBoxContainer.new()
	_paired_box.add_child(row)

	var re_pair := M3Button.new()
	re_pair.text = "Re-pair"
	re_pair.button_variant = M3Button.Variant.TONAL
	re_pair.pressed.connect(func():
		SystemManager.network.clear_paired_credentials()
		_start_pairing()
	)
	row.add_child(re_pair)

	var unpair := M3Button.new()
	unpair.text = "Unpair"
	unpair.button_variant = M3Button.Variant.TEXT
	unpair.pressed.connect(func():
		SystemManager.network.clear_paired_credentials()
		_indicator.set_status(Indicator.Status.NEUTRAL, "Unpaired - token revoked? Revoke it in the RomM web UI if needed")
		_update_mode_visibility()
	)
	row.add_child(unpair)

func _build_connect_box() -> void:
	_connect_box = VBoxContainer.new()
	add_child(_connect_box)

	var button_row := HBoxContainer.new()
	_connect_box.add_child(button_row)

	_main_button = M3Button.new()
	_main_button.text = test_button_text
	_main_button.button_variant = test_button_variant
	_main_button.button_size = test_button_size
	_main_button.pressed.connect(_start_pairing)
	button_row.add_child(_main_button)

	_code_toggle = M3Button.new()
	_code_toggle.text = "Use 8-digit code"
	_code_toggle.button_variant = M3Button.Variant.TEXT
	_code_toggle.pressed.connect(func():
		_code_mode = not _code_mode
		_update_mode_visibility()
	)
	button_row.add_child(_code_toggle)

	_legacy_toggle = M3Button.new()
	_legacy_toggle.text = "Legacy login"
	_legacy_toggle.button_variant = M3Button.Variant.TEXT
	_legacy_toggle.pressed.connect(func():
		_legacy_mode = not _legacy_mode
		_update_mode_visibility()
	)
	button_row.add_child(_legacy_toggle)

func _build_code_box() -> void:
	_code_box = VBoxContainer.new()
	add_child(_code_box)

	var hint := M3Label.new()
	hint.text = "In the RomM web UI: Administration > Client API Tokens, create a token and generate its pairing code (8 digits, valid 5 minutes)."
	hint.label_style = M3Label.Style.BODY_SMALL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_code_box.add_child(hint)

	_code_field = M3TextField.new()
	_code_field.label_text = "Pairing code"
	_code_field.placeholder_text = "12345678"
	_code_box.add_child(_code_field)

	_exchange_button = M3Button.new()
	_exchange_button.text = "Exchange code"
	_exchange_button.button_variant = M3Button.Variant.TONAL
	_exchange_button.pressed.connect(_on_exchange_pressed)
	_code_box.add_child(_exchange_button)

func _build_legacy_box() -> void:
	_legacy_box = VBoxContainer.new()
	add_child(_legacy_box)

	var hint := M3Label.new()
	hint.text = "For RomM servers older than 5.0: sign in with username + password (stored on this device)."
	hint.label_style = M3Label.Style.BODY_SMALL
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_legacy_box.add_child(hint)

	_username_field = M3TextField.new()
	_username_field.label_text = "Username"
	_username_field.placeholder_text = "username"
	_legacy_box.add_child(_username_field)

	_password_field = M3TextField.new()
	_password_field.label_text = "Password"
	_password_field.placeholder_text = "password"
	_password_field.secret = true
	_legacy_box.add_child(_password_field)

	_legacy_test_button = M3Button.new()
	_legacy_test_button.text = "Test Connection"
	_legacy_test_button.button_variant = M3Button.Variant.TONAL
	_legacy_test_button.pressed.connect(test_connection)
	_legacy_box.add_child(_legacy_test_button)

func _build_pairing_box() -> void:
	_pairing_box = VBoxContainer.new()
	_pairing_box.add_theme_constant_override("separation", M3Units.dp(8))
	add_child(_pairing_box)

	var instruction := M3Label.new()
	instruction.text = "Approve this device on your RomM server:"
	instruction.label_style = M3Label.Style.BODY_MEDIUM
	_pairing_box.add_child(instruction)

	_open_browser_button = M3Button.new()
	_open_browser_button.text = "Open RomM & Approve"
	_open_browser_button.icon_name = "open-in-new"
	_open_browser_button.button_variant = M3Button.Variant.FILLED
	_open_browser_button.m3_tooltip_text = "Opens the RomM approval page in your browser with the code filled in. Kyodai keeps waiting while you approve, then connects when you come back."
	_open_browser_button.pressed.connect(func():
		if _verification_complete_url != "":
			OS.shell_open(_verification_complete_url)
	)
	_pairing_box.add_child(_open_browser_button)

	_verification_label = M3Label.new()
	_verification_label.label_style = M3Label.Style.BODY_SMALL
	_verification_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pairing_box.add_child(_verification_label)

	_user_code_label = M3Label.new()
	_user_code_label.label_style = M3Label.Style.DISPLAY_SMALL
	_user_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pairing_box.add_child(_user_code_label)

	_qr_rect = QRCodeRectNode.new()
	_qr_rect.mode = QRCodeData.Mode.BYTE
	_qr_rect.custom_minimum_size = Vector2(M3Units.dp(180), M3Units.dp(180))
	_qr_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_qr_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_qr_rect.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_pairing_box.add_child(_qr_rect)

	_pairing_status = M3Label.new()
	_pairing_status.label_style = M3Label.Style.BODY_SMALL
	_pairing_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pairing_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pairing_box.add_child(_pairing_status)

	_cancel_pair_button = M3Button.new()
	_cancel_pair_button.text = "Cancel pairing"
	_cancel_pair_button.button_variant = M3Button.Variant.TEXT
	_cancel_pair_button.pressed.connect(func():
		_cancel_polling()
		_pairing_active = false
		_indicator.set_status(Indicator.Status.NEUTRAL, "Pairing cancelled")
		_update_mode_visibility()
	)
	_pairing_box.add_child(_cancel_pair_button)

func _update_mode_visibility() -> void:
	var paired := SystemManager.network.has_token()
	if _paired_box:
		_paired_box.visible = paired
	if _connect_box:
		_connect_box.visible = not paired and not _pairing_active
	if _code_box:
		_code_box.visible = _code_mode and not paired and not _pairing_active
	if _legacy_box:
		_legacy_box.visible = _legacy_mode and not paired and not _pairing_active
	if _pairing_box:
		_pairing_box.visible = _pairing_active

func load_from_settings() -> void:
	var url_setting = DataManager.get_setting("romm_url")
	_url_field.text = url_setting.value if url_setting else ""

	var user_setting = DataManager.get_setting("romm_username")
	_username_field.text = user_setting.value if user_setting else ""

	var pass_setting = DataManager.get_setting("romm_password")
	_password_field.text = pass_setting.value if pass_setting else ""

func save_to_settings(only_if_complete: bool = false) -> void:
	var url := _url_field.text.strip_edges()
	var username := _username_field.text.strip_edges()
	var password := _password_field.text.strip_edges()

	if only_if_complete and url.is_empty():
		return

	# Never persist an insecure http:// configuration the user hasn't
	# explicitly acknowledged - the OOBE wizard saves without testing (KYD-07).
	if _is_insecure_http(url) and _http_ack_checkbox and not _http_ack_checkbox.button_pressed:
		if _indicator:
			_indicator.set_status(Indicator.Status.ERROR, "Insecure http:// connection - tick the acknowledgment to save")
		return

	# Persist the acknowledgment for this origin so it survives restarts;
	# switching to https leaves any stored ack untouched (it may be needed
	# again if the user switches back to the same http origin).
	var ack_setting = DataManager.get_setting("romm_insecure_http_ack")
	if ack_setting and _is_insecure_http(url):
		DataManager.set_setting(_http_origin(url), ack_setting)

	var url_setting = DataManager.get_setting("romm_url")
	if url_setting:
		DataManager.set_setting(url, url_setting)

	# Legacy credentials only matter on the Basic-auth path; a paired token
	# is already persisted by store_paired_credentials().
	if not only_if_complete or (not username.is_empty() and not password.is_empty()):
		var user_setting = DataManager.get_setting("romm_username")
		var pass_setting = DataManager.get_setting("romm_password")
		if user_setting:
			DataManager.set_setting(username, user_setting)
		if pass_setting:
			DataManager.set_setting(password, pass_setting)

## Shared pre-flight for pairing and code exchange: validates the URL and the
## insecure-http acknowledgment. Returns the cleaned base URL ("" = rejected).
func _validated_base_url() -> String:
	var url := _url_field.text.strip_edges()
	if url.is_empty():
		_indicator.set_status(Indicator.Status.ERROR, "Enter your RomM server URL first")
		connection_failed.emit()
		return ""
	if _is_insecure_http(url) and _http_ack_checkbox and not _http_ack_checkbox.button_pressed:
		_indicator.set_status(Indicator.Status.ERROR, "Insecure http:// connection - tick the acknowledgment below to continue")
		connection_failed.emit()
		return ""
	return url

# ==================== DEVICE PAIRING (RomM 5.0+) ====================

func _start_pairing() -> void:
	var url := _validated_base_url()
	if url.is_empty():
		return

	_cancel_polling()
	_main_button.disabled = true
	_indicator.set_status(Indicator.Status.WARNING, "Checking server...")

	SystemManager.network.fetch_server_version(url, func(version: String, error: String):
		if not is_instance_valid(_main_button):
			return
		_main_button.disabled = false
		if error != "":
			_indicator.set_status(Indicator.Status.ERROR, error)
			connection_tested.emit(false)
			connection_failed.emit()
			return
		if not NetworkSubManager.version_at_least(version, NetworkSubManager.DEVICE_AUTH_MIN_VERSION):
			var shown := version if version != "" else "unknown"
			_indicator.set_status(Indicator.Status.ERROR, "Pairing needs RomM 5.0+ (server is %s) - use Legacy login" % shown)
			connection_tested.emit(false)
			connection_failed.emit()
			return

		_main_button.disabled = true
		_indicator.set_status(Indicator.Status.WARNING, "Requesting pairing code...")
		SystemManager.network.device_auth_init(url, func(result: Dictionary):
			if not is_instance_valid(_main_button):
				return
			_main_button.disabled = false
			var status: int = result.get("status", 0)
			if status != 201 or not result.data is Dictionary:
				var message := "Pairing init failed (HTTP %d)" % status
				if status == 429:
					message = "Too many attempts - try again later"
				elif status == 0:
					message = str(result.get("error", "Connection failed"))
				_indicator.set_status(Indicator.Status.ERROR, message)
				connection_tested.emit(false)
				connection_failed.emit()
				return
			_show_pairing_view(url, result.data)
		)
	)

func _absolutize(base_url: String, path: String) -> String:
	if path.begins_with("http"):
		return path
	if not path.begins_with("/"):
		path = "/" + path
	return base_url.rstrip("/") + path

func _show_pairing_view(base_url: String, init_data: Dictionary) -> void:
	_pairing_active = true
	_pairing_base_url = base_url
	_update_mode_visibility()

	_user_code_label.text = str(init_data.get("user_code", ""))
	_verification_complete_url = _absolutize(base_url, str(init_data.get("verification_path_complete", "")))
	_verification_label.text = "or open on another device: " + _absolutize(base_url, str(init_data.get("verification_path", "")))
	_qr_rect.data = _verification_complete_url.to_utf8_buffer()
	_pairing_status.text = "Waiting for approval... (code expires in %d min)" % maxi(1, int(init_data.get("expires_in", 600)) / 60)
	_indicator.set_status(Indicator.Status.WARNING, "Waiting for approval in the RomM web UI")

	_poller = DeviceAuthPoller.new()
	_poller.finished.connect(_on_pairing_finished)
	_poller.start(SystemManager.network, base_url, init_data)

func _cancel_polling() -> void:
	if _poller:
		_poller.cancel()
		_poller = null

func _on_pairing_finished(outcome: String, data: Dictionary) -> void:
	_poller = null
	_pairing_active = false
	match outcome:
		"approved":
			SystemManager.network.store_paired_credentials(_pairing_base_url, str(data.get("access_token", "")), str(data.get("device_id", "")))
			_indicator.set_status(Indicator.Status.SUCCESS, "Paired and connected")
			SystemManager.notifications.show_notification("Paired with RomM successfully", SystemManager.notifications.Type.SUCCESS)
			connection_tested.emit(true)
			connection_succeeded.emit()
		"denied":
			_indicator.set_status(Indicator.Status.ERROR, "Pairing was denied on the server")
			connection_tested.emit(false)
			connection_failed.emit()
		"expired":
			_indicator.set_status(Indicator.Status.ERROR, "Pairing code expired - try again")
			connection_tested.emit(false)
			connection_failed.emit()
		"failed":
			_indicator.set_status(Indicator.Status.ERROR, str(data.get("error", "Pairing failed")))
			connection_tested.emit(false)
			connection_failed.emit()
		"cancelled":
			_indicator.set_status(Indicator.Status.NEUTRAL, "Pairing cancelled")
	_update_mode_visibility()

# ==================== 8-DIGIT CODE EXCHANGE ====================

func _on_exchange_pressed() -> void:
	var url := _validated_base_url()
	if url.is_empty():
		return
	var code := _code_field.text.strip_edges()
	if code.is_empty():
		_indicator.set_status(Indicator.Status.ERROR, "Enter the 8-digit pairing code")
		return

	_exchange_button.disabled = true
	_indicator.set_status(Indicator.Status.WARNING, "Exchanging code...")
	SystemManager.network.exchange_pairing_code(url, code, func(result: Dictionary):
		if not is_instance_valid(_exchange_button):
			return
		_exchange_button.disabled = false
		var status: int = result.get("status", 0)
		if status == 200 and result.data is Dictionary and str(result.data.get("raw_token", "")) != "":
			SystemManager.network.store_paired_credentials(url, str(result.data.raw_token), str(result.data.get("device_id", "")))
			_indicator.set_status(Indicator.Status.SUCCESS, "Paired and connected")
			SystemManager.notifications.show_notification("Paired with RomM successfully", SystemManager.notifications.Type.SUCCESS)
			connection_tested.emit(true)
			connection_succeeded.emit()
			_update_mode_visibility()
			return
		var message := "Exchange failed (HTTP %d)" % status
		match status:
			0: message = str(result.get("error", "Connection failed"))
			404: message = "Invalid or expired pairing code"
			429: message = "Too many attempts - try again later"
		_indicator.set_status(Indicator.Status.ERROR, message)
		connection_tested.emit(false)
		connection_failed.emit()
	)

# ==================== LEGACY BASIC AUTH (RomM < 5.0) ====================

func test_connection() -> void:
	var url := _url_field.text.strip_edges()
	var username := _username_field.text.strip_edges()
	var password := _password_field.text.strip_edges()

	if url.is_empty() or username.is_empty() or password.is_empty():
		_indicator.set_status(Indicator.Status.ERROR, "Fill in all fields")
		connection_tested.emit(false)
		connection_failed.emit()
		return

	if _is_insecure_http(url) and _http_ack_checkbox and not _http_ack_checkbox.button_pressed:
		_indicator.set_status(Indicator.Status.ERROR, "Insecure http:// connection - tick the acknowledgment below to continue")
		connection_tested.emit(false)
		connection_failed.emit()
		return

	if _legacy_test_button:
		_legacy_test_button.disabled = true
	_indicator.set_status(Indicator.Status.WARNING, "Testing connection...")

	save_to_settings()
	DataManager.save_settings()

	SystemManager.network.test_connection(func(online: bool):
		if _legacy_test_button:
			_legacy_test_button.disabled = false

		if online:
			_indicator.set_status(Indicator.Status.SUCCESS, "Connected and authenticated")
			SystemManager.notifications.show_notification("Connected to RomM successfully", SystemManager.notifications.Type.SUCCESS)
			connection_tested.emit(true)
			connection_succeeded.emit()
		else:
			if not SystemManager.network.is_configured():
				_indicator.set_status(Indicator.Status.NEUTRAL, "Not configured (check URL, username, password)")
				SystemManager.notifications.show_notification("RomM not configured - check URL, username, password", SystemManager.notifications.Type.ERROR)
			else:
				_indicator.set_status(Indicator.Status.ERROR, "Connection failed - check credentials")
				SystemManager.notifications.show_notification("Connection failed - check credentials", SystemManager.notifications.Type.ERROR)
			connection_tested.emit(false)
			connection_failed.emit()
	)

func refresh_indicator() -> void:
	if not _indicator:
		return

	if SystemManager.network.is_online():
		_indicator.set_status(Indicator.Status.SUCCESS, "Connected and authenticated" if not SystemManager.network.has_token() else "Connected (paired token)")
	elif not SystemManager.network.is_configured():
		_indicator.set_status(Indicator.Status.NEUTRAL, "Not configured")
	elif SystemManager.network.has_token():
		_indicator.set_status(Indicator.Status.ERROR, "Paired, but disconnected - re-pair if the token was revoked")
	else:
		_indicator.set_status(Indicator.Status.ERROR, "Disconnected")

func focus_url_field() -> void:
	if _url_field:
		_url_field.grab_focus()

func get_url() -> String:
	return _url_field.text if _url_field else ""

func get_username() -> String:
	return _username_field.text if _username_field else ""

func get_password() -> String:
	return _password_field.text if _password_field else ""
