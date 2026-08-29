extends Sprite2D
## Visual representation of a single card.
## Phase 2 game logic keeps its own plain card data and does not use this node.

# Deck skin. kid_set only for now: og_set uses a different filename scheme
# (e.g. "ace_of_spades.png") and ships no card back.
const CARD_SET := "kid_set"
const BACK := "back_dark"  # or "back_light"

const _RANK_TOKENS := {11: "J", 12: "Q", 13: "K", 14: "A"}

@export_enum("clubs", "diamonds", "hearts", "spades") var suit := "clubs":
	set(value):
		suit = value
		_refresh_texture()
@export_range(2, 14) var rank := 6:  # 11=J 12=Q 13=K 14=A
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


func _refresh_texture() -> void:
	if not is_node_ready():
		return
	texture = load(_texture_path())


func _texture_path() -> String:
	if not face_up:
		return "res://cards/%s/%s.png" % [CARD_SET, BACK]
	var rank_token: String = _RANK_TOKENS.get(rank, str(rank))
	return "res://cards/%s/%s_%s.png" % [CARD_SET, suit, rank_token]
