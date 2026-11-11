class_name UserAvatar
extends Control

## Circular profile avatar for the controls bar. Shows the current RomM
## user's avatar image, falling back to a generic account icon when no
## avatar is set or the image has not loaded yet. Decorative only: all
## input is ignored.
##
## Rendering reuses the card effect pipeline (EffectStack + MediaContainer):
## the base effect center-crops the image and clips it to a circle via the
## rounded-rect SDF (corner_radius_ratio = 1.0). The white ring is a solid
## backing disc drawn behind the stack: the border shader cannot anti-alias
## its inner edge (hard discard), so instead the media is inset by the ring
## width and both visible edges come from shaders that do AA.

const SIZE_DP := 56

## Ring width as a ratio of the avatar width (media inset revealing the disc).
const BORDER_RATIO := 0.05

## Ring/disc color.
const BORDER_COLOR := Color.WHITE

## Center-crop factor applied before upload so the subject fills the circle.
const CENTER_CROP := 0.70

## Sources at or below this width are treated as pixel art and sampled with
## nearest-neighbor filtering so they stay crisp; larger sources use linear.
const PIXEL_ART_MAX_WIDTH := 128

const DISC_SHADER := """shader_type canvas_item;

uniform vec4 color : source_color = vec4(1.0);

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float d = length(p);
	float aa = fwidth(d) * 1.5;
	COLOR = vec4(color.rgb, color.a * (1.0 - smoothstep(1.0 - aa, 1.0, d)));
}
"""

var _fallback_icon: FontIcon = null
var _media_container: MediaContainer = null
var _stack: EffectStack = null

func _ready() -> void:
	custom_minimum_size = Vector2.ONE * M3Units.dp(SIZE_DP)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Backing disc: the visible white ring once the inset image sits on top.
	# Also serves as the placeholder background behind the fallback icon.
	var disc := ColorRect.new()
	disc.color = BORDER_COLOR
	disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	disc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var disc_shader := Shader.new()
	disc_shader.code = DISC_SHADER
	var disc_material := ShaderMaterial.new()
	disc_material.shader = disc_shader
	disc_material.set_shader_parameter("color", BORDER_COLOR)
	disc.material = disc_material
	add_child(disc)

	_fallback_icon = FontIcon.new()
	_fallback_icon.icon_settings = FontIconSettings.new()
	_fallback_icon.icon_settings.icon_font = "MaterialIcons"
	_fallback_icon.icon_settings.icon_name = "account-circle"
	_fallback_icon.icon_settings.icon_size = int(M3Units.dp(SIZE_DP))
	_fallback_icon.icon_settings.icon_color = M3Theme.get_on_surface_variant()
	_fallback_icon.icon_settings.outline_color = Color.TRANSPARENT
	_fallback_icon.icon_settings.shadow_color = Color.TRANSPARENT
	_fallback_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fallback_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fallback_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_fallback_icon)

	_media_container = MediaContainer.new()
	_media_container.corner_radius_ratio = 1.0
	_media_container.edge_aa_enabled = true
	_media_container.bounds = Rect2(Vector2.ZERO, size)

	# Base effect only (auto-added); no border effect — its inner edge cannot
	# be anti-aliased, which produced the jagged ring seam.
	_stack = EffectStack.new()
	_stack.set_parent_rid(get_canvas_item())
	_stack.set_clip_children(false)
	_stack.initialize(_media_container, [{
		"layer_id": "avatar_ring_inset",
		"effect_id": "inset",
		"settings": {"inset_ratio": BORDER_RATIO},
	}], "base_card")
	# The stack renders via raw RenderingServer canvas items; without an
	# explicit draw index the backing disc node can draw on top of it.
	_stack.set_draw_index(1)
	# Inset the media by the ring width so the backing disc shows as the ring.
	_stack.force_refresh()
	# Hidden until an avatar image arrives; the fallback icon shows instead.
	_stack.set_visible(false)

	resized.connect(_on_resized)

## Re-bake dp-derived sizes on UI scale changes (the avatar lives in the
## control bar, outside the view tree that gets rebuilt on scale changes).
func refresh_scale() -> void:
	custom_minimum_size = Vector2.ONE * M3Units.dp(SIZE_DP)
	if _fallback_icon and _fallback_icon.icon_settings:
		_fallback_icon.icon_settings.icon_size = int(M3Units.dp(SIZE_DP))

func _on_resized() -> void:
	if _media_container:
		_media_container.bounds = Rect2(Vector2.ZERO, size)
	if _stack:
		_stack.force_refresh()
		_reapply_texture_filter()

func set_avatar_image(image: Image) -> void:
	if image == null or image.is_empty() or not _stack:
		clear_avatar()
		return
	var cropped := _center_crop(image)
	_stack.set_game_texture(ImageTexture.create_from_image(cropped))
	_pixel_art = cropped.get_width() <= PIXEL_ART_MAX_WIDTH
	_reapply_texture_filter()
	_stack.set_visible(true)
	_fallback_icon.visible = false

func clear_avatar() -> void:
	if _stack:
		_stack.set_visible(false)
	_fallback_icon.visible = true

func _notification(what: int) -> void:
	# Layout/navigation changes can reparent this control without destroying it.
	# Keep the effect stack alive across those tree exits and release its RIDs
	# only on final deletion; _ready() is not called again on re-entry.
	if what == NOTIFICATION_PREDELETE and _stack:
		_stack.free_rids()
		_stack = null

var _pixel_art: bool = false

func _reapply_texture_filter() -> void:
	var base_effect := _stack.get_effect("base") if _stack else null
	if base_effect:
		base_effect.set_texture_filter(
			RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_NEAREST if _pixel_art
			else RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_LINEAR)

func _center_crop(image: Image) -> Image:
	var w := image.get_width()
	var h := image.get_height()
	var cw := int(w * CENTER_CROP)
	var ch := int(h * CENTER_CROP)
	if cw <= 0 or ch <= 0 or (cw == w and ch == h):
		return image
	return image.get_region(Rect2i(int((w - cw) / 2.0), int((h - ch) / 2.0), cw, ch))
