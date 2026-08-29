class_name CardData
extends RefCounted
## Plain card value used by the game logic. Not a node, not drawn.
## The view maps one of these to a `card.tscn` instance for display.

enum Suit { CLUBS, DIAMONDS, HEARTS, SPADES }

const SUIT_NAMES := ["clubs", "diamonds", "hearts", "spades"]
const RANK_NAMES := {11: "J", 12: "Q", 13: "K", 14: "A"}

var suit: int  # 0..3, index into SUIT_NAMES
var rank: int  # 2..14 (11=J 12=Q 13=K 14=A); a 36-card deck uses 6..14


func _init(card_suit: int, card_rank: int) -> void:
	suit = card_suit
	rank = card_rank


## True if this card, played in defense, beats `attack`.
func beats(attack: CardData, trump_suit: int) -> bool:
	if suit == attack.suit:
		return rank > attack.rank
	return suit == trump_suit and attack.suit != trump_suit


func is_trump(trump_suit: int) -> bool:
	return suit == trump_suit


func _to_string() -> String:
	var r: String = RANK_NAMES.get(rank, str(rank))
	return "%s%s" % [r, SUIT_NAMES[suit][0].to_upper()]
