extends Sprite2D
## Visual representation of a single card.
## The game logic (durak_game.gd) keeps its own plain CardData and never uses
## this node; the view maps one CardData to one of these for display.

# Deck skin. Both sets share the scheme <suit>_<rank>.png + back_*.png.
const CARD_SET := "og_set"
const BACK := "back_red" # og_set: back_red/back_blue; kid_set: back_dark/back_light

const _RANK_TOKENS := {11: "J", 12: "Q", 13: "K", 14: "A"}
var _joker := false # shows the Joker art (set_special(&"joker"))


## The Joker: by its special, or by its rank - the engine's Joker is rank 15,
## which the view sees before set_special() runs.
func _is_joker() -> bool:
	return _joker or rank == CardData.JOKER_RANK

# One ShaderMaterial per card (its own, not shared) for the hover fake-3D tilt
# and the "can't play this" red strike - both need per-card params, so they
# live in one shader instead of fighting over the single material slot.
const _CARD_FX_SHADER := preload("res://shaders/card_fx.gdshader")
var _fx: ShaderMaterial

@export_enum("clubs", "diamonds", "hearts", "spades") var suit := "clubs":
	set(value):
		suit = value
		_refresh_texture()
@export_range(2, 15) var rank := 6: # 11=J 12=Q 13=K 14=A 15=Joker
	set(value):
		rank = value
		_refresh_texture()
@export var face_up := true:
	set(value):
		face_up = value
		_refresh_texture()


func _ready() -> void:
	_refresh_texture()


func setup(card_suit: String, card_rank: int, is_face_up := true) -> void:
	suit = card_suit
	rank = card_rank
	face_up = is_face_up


## Special card: family-paint frame + stencilled nameplate, all drawn in
## card_fx.gdshader. The name is rendered once into the NameView SubViewport
## and handed to the shader as a texture, so it tilts/bends with the card.
func set_special(id: StringName) -> void:
	var known := SpecialCards.exists(id)
	if (id == &"joker") != _joker: # the Joker has its own art (and no rank)
		_joker = id == &"joker"
		_refresh_texture()
	if known:
		var view: SubViewport = $NameView
		var label := $NameView/SpecialLabel as Label
		# dual cards ("Attack / Defence") stack their two names; single names get
		# one big line - either way as large as the 430x109 plate fits
		var card_name: String = SpecialCards.DEFS[id].name
		var dual := card_name.contains(" / ")
		label.text = card_name.replace(" / ", "\n")
		label.add_theme_font_size_override("font_size", 42 if dual else (60 if card_name.length() <= 10 else 50))
		view.render_target_update_mode = SubViewport.UPDATE_ONCE
		_fx_material().set_shader_parameter("name_tex", view.get_texture())
		var family: int = SpecialCards.DEFS[id].family
		var paint: Color = SpecialCards.FAMILY_COLORS[family]
		_fx_material().set_shader_parameter("family_color", paint)
		_fx_material().set_shader_parameter("family_outline",
			SpecialCards.FAMILY_OUTLINES.get(family, paint.darkened(0.55)))
		_fx_material().set_shader_parameter("stripes", 1.0 if family in SpecialCards.FAMILY_STRIPES else 0.0)
	if known or _fx != null:
		# the Joker gets the gold metal treatment instead of a frame + nameplate
		var is_joker := id == &"joker"
		_fx_material().set_shader_parameter("special", 1.0 if known and not is_joker else 0.0)
		_fx_material().set_shader_parameter("joker", 1.0 if is_joker else 0.0)


## Shared hover behaviour (draft overlay, Card Archive): ease toward
## `home_pos` (lifted by `lift` while hovered), grow by `grow`, tip toward the
## mouse in fake 3D (up to `tilt_deg`), and push the shadow out. `mouse` must be
## in this card's parent's space. `idle_tilt` = a resting wobble when not hovered.
func hover_follow(mouse: Vector2, hovered: bool, home_pos: Vector2, home_scale: Vector2,
		weight: float, grow := 1.18, lift := 31.0, tilt_deg := 14.0, idle_tilt := Vector2.ZERO) -> void:
	var half := texture.get_size() * home_scale * 0.5
	var goal := home_pos
	var tilt := idle_tilt
	if hovered:
		var lean := ((mouse - home_pos) / half).clamp(-Vector2.ONE, Vector2.ONE)
		goal += Vector2(0, -lift)
		tilt = Vector2(deg_to_rad(tilt_deg) * -lean.y, deg_to_rad(tilt_deg) * lean.x)
	position = position.lerp(goal, weight)
	scale = scale.lerp(home_scale * (grow if hovered else 1.0), weight)
	set_hover_tilt(tilt.x, tilt.y, weight)
	set_lifted(hovered, weight)


## A Hazard's status on this card (CardData.status): &"frozen", &"irradiated", or &"".
func set_status(status: StringName) -> void:
	if _fx == null and status == &"":
		return
	_fx_material().set_shader_parameter("irradiated", 1.0 if status == &"irradiated" else 0.0)
	_fx_material().set_shader_parameter("frozen", 1.0 if status == &"frozen" else 0.0)


## Spilt Samogon stuck to the table edge: an amber, glossy glaze with drips.
func set_sticky(on: bool) -> void:
	if _fx == null and not on:
		return
	_fx_material().set_shader_parameter("sticky", 1.0 if on else 0.0)


## 0..1: how far the card has burned away (Flame Hazard / Purge).
func set_burn(amount: float) -> void:
	_fx_material().set_shader_parameter("burn", amount)


## Soft drop shadow (a black copy of the card behind it); pushed further out
## while `lifted` (hovered/dragged), so raised cards read as off the table.
const SHADOW_REST := Vector2(16, 22)
const SHADOW_LIFTED := Vector2(40, 58)
var _shadow: Sprite2D
func set_lifted(on: bool, weight := 1.0) -> void:
	if _shadow:
		_shadow.position = _shadow.position.lerp(SHADOW_LIFTED if on else SHADOW_REST, weight)


## Toggles the gold shimmer overlay on/off - lives on the same _fx material as
## tilt/invalid (not a separate one) since any trump-suited card can need all
## three at once: a trump card sitting in your hand still hovers, still tilts,
## and can still be marked unplayable, same as any other card.
func set_trump_shimmer(enabled: bool) -> void:
	_fx_material().set_shader_parameter("trump", 1.0 if enabled else 0.0)


func _fx_material() -> ShaderMaterial:
	if _fx == null:
		_fx = ShaderMaterial.new()
		_fx.shader = _CARD_FX_SHADER
		_fx.set_shader_parameter("seed", Vector2(randf(), randf()) * 100.0) # cosmetic only, not game RNG
		material = _fx
	return _fx


## Red strike-through for "you can't play this right now". Combines with (does
## not replace) the modulate.a dimming the board already does.
func set_invalid(is_invalid: bool) -> void:
	_fx_material().set_shader_parameter("invalid", 1.0 if is_invalid else 0.0)


## Paper flex along the long axis (see card_fx.gdshader's `bend`). 0 = flat.
func set_bend(amount: float) -> void:
	if _fx == null and amount == 0.0:
		return
	_fx_material().set_shader_parameter("bend", amount)


## Fake-3D hover tilt in radians. (0, 0) = flat; weight 1.0 snaps, anything
## less springs there (slightly under-damped: a hair of overshoot, then it
## settles, so the card feels like it has weight). See card_fx.gdshader for
## the axis conventions.
const TILT_STIFFNESS := 170.0
const TILT_DAMPING := 19.0 # critical would be ~26; lower = more overshoot
var _tilt := Vector2.ZERO
var _tilt_vel := Vector2.ZERO
func set_hover_tilt(rot_x: float, rot_y: float, weight := 1.0) -> void:
	if _fx == null and rot_x == 0.0 and rot_y == 0.0 and _tilt == Vector2.ZERO:
		return # nothing to do; don't spin up an FX material for an untilted card (all backs)
	var target := Vector2(rot_x, rot_y)
	if weight >= 1.0:
		_tilt = target
		_tilt_vel = Vector2.ZERO
	else:
		var dt := minf(get_process_delta_time(), 1.0 / 30.0) # clamp: a hitch mustn't explode the spring
		_tilt_vel += ((target - _tilt) * TILT_STIFFNESS - _tilt_vel * TILT_DAMPING) * dt
		_tilt += _tilt_vel * dt
	var mat := _fx_material()
	mat.set_shader_parameter("rot_x", _tilt.x)
	mat.set_shader_parameter("rot_y", _tilt.y)


## Invisible margin around the card (texture px): card_fx.gdshader draws the
## tilted/bent card into it, so the card never has to shrink to stay in-quad.
const PAD := 64.0

func _refresh_texture() -> void:
	texture = load(_texture_path())
	var padded := Rect2(-Vector2.ONE * PAD, texture.get_size() + Vector2.ONE * PAD * 2.0)
	region_enabled = true
	region_rect = padded
	# backs stay plain (stacked piles would pile their shadows into a blob)
	if face_up and _shadow == null:
		_shadow = Sprite2D.new()
		_shadow.show_behind_parent = true
		_shadow.use_parent_material = true # same tilt/bend warp as the card itself
		_shadow.modulate = Color(0, 0, 0, 0.35)
		_shadow.position = SHADOW_REST
		add_child(_shadow)
	if _shadow:
		_shadow.texture = texture
		_shadow.region_enabled = true
		_shadow.region_rect = padded
		_shadow.visible = face_up
	# every card gets the FX material now: backs are drawn procedurally by it too
	_fx_material().set_shader_parameter("face", 1.0 if face_up else 0.0)
	if face_up:
		_refresh_rank()


## Corner ranks drawn in the game's font (card_fx.gdshader erases the printed
## ones and lays this in): render the rank once into RankView, in the suit's ink.
const RED_INK := Color(0.78, 0.05, 0.05)
## The theme font with full-height "lining" figures switched on (OpenType
## `lnum`): its default old-style digits only reach lowercase height, so a 10
## stood half as tall as a K. Built once, shared by every card.
static var _rank_font: FontVariation
static func rank_font(base: Font) -> FontVariation:
	if _rank_font == null:
		_rank_font = FontVariation.new()
		_rank_font.base_font = base
		var ts := TextServerManager.get_primary_interface()
		_rank_font.opentype_features = {ts.name_to_tag("lnum"): 1}
	return _rank_font
const BLACK_INK := Color(0.08, 0.07, 0.06)
func _refresh_rank() -> void:
	var view := get_node_or_null("RankView") as SubViewport
	if view == null:
		return
	if _is_joker(): # the Joker art has no rank to replace - leave its lettering be
		_fx_material().set_shader_parameter("use_rank", 0.0)
		return
	var label := view.get_node("RankLabel") as Label
	label.text = _RANK_TOKENS.get(rank, str(rank))
	var font := rank_font(label.get_theme_font("font"))
	label.add_theme_font_override("font", font)
	# Size + place by the font's own metrics so the glyph fills the box: a
	# centred Label keeps room for accents/descenders and left the rank at
	# barely half the box. Cap height ~0.7 em -> aim it at ~88% of the box
	# height with the baseline near the bottom; shrink if too wide ("10").
	var box := Vector2(view.size)
	var fs := int(box.y * 0.88 / 0.7)
	var w := font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	if w > box.x * 0.96:
		fs = int(fs * box.x * 0.96 / w)
	# Q is the one rank with a tail below the baseline: a bit smaller and
	# lifted so the tail (what tells it from an O) stays inside the box
	var baseline := box.y * 0.94
	if label.text == "Q":
		fs = int(fs * 0.74)
		baseline = box.y * 0.66
	label.add_theme_font_size_override("font_size", fs)
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.size = Vector2(box.x, font.get_height(fs))
	label.position = Vector2(0, baseline - font.get_ascent(fs))
	label.add_theme_color_override("font_color", RED_INK if suit in ["hearts", "diamonds"] else BLACK_INK)
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	_fx_material().set_shader_parameter("rank_tex", view.get_texture())
	_fx_material().set_shader_parameter("use_rank", 1.0)


func _texture_path() -> String:
	if not face_up:
		return "res://assets/cards/%s/%s.png" % [CARD_SET, BACK]
	if _is_joker():
		return "res://assets/cards/%s/joker_black.png" % CARD_SET
	var rank_token: String = _RANK_TOKENS.get(rank, str(rank))
	return "res://assets/cards/%s/%s_%s.png" % [CARD_SET, suit, rank_token]
