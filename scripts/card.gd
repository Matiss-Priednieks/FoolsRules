extends Sprite2D
## Visual representation of a single card.
## The game logic (durak_game.gd) keeps its own plain CardData and never uses
## this node; the view maps one CardData to one of these for display.

# Deck skin. Both sets share the scheme <suit>_<rank>.png + back_*.png.
const CARD_SET := "og_set"
const BACK := "back_red" # og_set: back_red/back_blue; kid_set: back_dark/back_light

const _RANK_TOKENS := {11: "J", 12: "Q", 13: "K", 14: "A"}

# Red diagonal strike-through for "you can't play this right now". Shared
# across every card instance - the shader has no per-card parameters, so one
# ShaderMaterial does for all of them instead of building one each.
const _INVALID_SHADER := preload("res://shaders/invalid_card.tres")
static var _invalid_material: ShaderMaterial

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


## Marks/unmarks this card with the red strike-through. Separate from - and
## meant to be combined with - the dimming (modulate.a) the board already does.
func set_invalid(is_invalid: bool) -> void:
	if not is_invalid:
		material = null
		return
	if _invalid_material == null:
		_invalid_material = ShaderMaterial.new()
		_invalid_material.shader = _INVALID_SHADER
	material = _invalid_material


func _refresh_texture() -> void:
	texture = load(_texture_path())


func _texture_path() -> String:
	if not face_up:
		return "res://cards/%s/%s.png" % [CARD_SET, BACK]
	var rank_token: String = _RANK_TOKENS.get(rank, str(rank))
	return "res://cards/%s/%s_%s.png" % [CARD_SET, suit, rank_token]
