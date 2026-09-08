extends Sprite2D
## Visual representation of a single card.
## The game logic (durak_game.gd) keeps its own plain CardData and never uses
## this node; the view maps one CardData to one of these for display.

# Deck skin. Both sets share the scheme <suit>_<rank>.png + back_*.png.
const CARD_SET := "og_set"
const BACK := "back_red" # og_set: back_red/back_blue; kid_set: back_dark/back_light

const _RANK_TOKENS := {11: "J", 12: "Q", 13: "K", 14: "A"}

# One ShaderMaterial per card (its own, not shared) for the hover fake-3D tilt
# and the "can't play this" red strike - both need per-card params, so they
# live in one shader instead of fighting over the single material slot.
const _CARD_FX_SHADER := preload("res://shaders/card_fx.gdshader")
var _fx: ShaderMaterial

@export_enum("clubs", "diamonds", "hearts", "spades") var suit := "clubs":
	set(value):
		suit = value
		_refresh_texture()
@export_range(2, 14) var rank := 6: # 11=J 12=Q 13=K 14=A
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


func _fx_material() -> ShaderMaterial:
	if _fx == null:
		_fx = ShaderMaterial.new()
		_fx.shader = _CARD_FX_SHADER
		material = _fx
	return _fx


## Red strike-through for "you can't play this right now". Combines with (does
## not replace) the modulate.a dimming the board already does.
func set_invalid(is_invalid: bool) -> void:
	_fx_material().set_shader_parameter("invalid", 1.0 if is_invalid else 0.0)


## Fake-3D hover tilt in radians, eased toward the target by `weight` (1.0 =
## snap). (0, 0) = flat. See card_fx.gdshader for the axis conventions.
var _tilt := Vector2.ZERO
func set_hover_tilt(rot_x: float, rot_y: float, weight := 1.0) -> void:
	if _fx == null and rot_x == 0.0 and rot_y == 0.0 and _tilt == Vector2.ZERO:
		return # nothing to do; don't spin up an FX material for an untilted card (all backs)
	_tilt = _tilt.lerp(Vector2(rot_x, rot_y), weight)
	var mat := _fx_material()
	mat.set_shader_parameter("rot_x", _tilt.x)
	mat.set_shader_parameter("rot_y", _tilt.y)


func _refresh_texture() -> void:
	texture = load(_texture_path())


func _texture_path() -> String:
	if not face_up:
		return "res://cards/%s/%s.png" % [CARD_SET, BACK]
	var rank_token: String = _RANK_TOKENS.get(rank, str(rank))
	return "res://cards/%s/%s_%s.png" % [CARD_SET, suit, rank_token]
