class_name CardData
extends RefCounted
## Plain card value used by the game logic. Not a node, not drawn.
## The view maps one of these to a `card.tscn` instance for display.

const SUIT_NAMES := ["clubs", "diamonds", "hearts", "spades"]
const RANK_NAMES := {11: "J", 12: "Q", 13: "K", 14: "A"}

var suit: int  # 0..3, index into SUIT_NAMES
var rank: int  # 2..14 (11=J 12=Q 13=K 14=A); a 36-card deck uses 6..14

## Roguelike layer: an effect id from SpecialCards.DEFS, or &"" for a plain card.
## Purely extra data - suit/rank/beats() are untouched, so a special is an
## ordinary ranked card in every rules respect (spec 3.1).
var special: StringName = &""


func _init(card_suit: int, card_rank: int, card_special: StringName = &"") -> void:
	suit = card_suit
	rank = card_rank
	special = card_special


func is_special() -> bool:
	return special != &""


## True if this card, played in defense, beats `attack`.
func beats(attack: CardData, trump_suit: int) -> bool:
	if suit == attack.suit:
		return rank > attack.rank
	return suit == trump_suit and attack.suit != trump_suit


func _to_string() -> String:
	var rank_name: String = RANK_NAMES.get(rank, str(rank))
	return "%s%s" % [rank_name, SUIT_NAMES[suit][0].to_upper()]
