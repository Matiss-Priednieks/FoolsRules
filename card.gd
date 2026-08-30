extends Sprite2D
## Visual representation of a single card.
## The game logic (durak_game.gd) keeps its own plain CardData and never uses
## this node; the view maps one CardData to one of these for display.

# Which deck skin to draw. Each set has its own filename scheme and card back.
const CARD_SET := "og_set"

const SETS := {
	"kid_set": {
		face = "{s}_{r}",      # e.g. spades_A, clubs_10
		ranks = {11: "J", 12: "Q", 13: "K", 14: "A"},
		back = "back_dark",    # or back_light
	},
	"og_set": {
		face = "{r}_of_{s}",   # e.g. ace_of_spades, 10_of_clubs
		ranks = {11: "jack", 12: "queen", 13: "king", 14: "ace"},
		back = "red_back",     # or blue_back
	},
}

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
	var cfg: Dictionary = SETS[CARD_SET]
	if not face_up:
		return "res://cards/%s/%s.png" % [CARD_SET, cfg.back]
	var rank_token: String = cfg.ranks.get(rank, str(rank))
	var file: String = (cfg.face as String).format({s = suit, r = rank_token})
	return "res://cards/%s/%s.png" % [CARD_SET, file]
