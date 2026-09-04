class_name Bot
## Dumb heuristic policy for the AI seats. Phase 4 will make this smarter.
## For now bots never translate, and they would rather pass than throw a card in.

## Returns one legal action for whichever bot seat should move now, or {} when
## every remaining legal action belongs to a seat in `excluded_seats` (a human,
## local or networked, whose moves this policy must never make on their behalf).
static func pick(game: DurakGame, excluded_seats: Array = []) -> Dictionary:
	var actions: Array[Dictionary] = []
	for seat in game.num_players:
		if seat not in excluded_seats:
			actions.append_array(game.get_legal_actions(seat))
	if actions.is_empty():
		return {}

	var trump: int = game.trump_suit

	# 1. Beat the attack with the cheapest card that does the job.
	var defends := actions.filter(func(action): return action.type == "defend")
	if not defends.is_empty():
		return _cheapest(defends, trump)

	var attacks := actions.filter(func(action): return action.type == "attack")

	# 2. Opening the bout: lead the cheapest card (no pass is offered here).
	if game.table.is_empty() and not attacks.is_empty():
		return _cheapest(attacks, trump)

	# 3. Otherwise rather pass than spend a card...
	var passes := actions.filter(func(action): return action.type == "pass")
	if not passes.is_empty():
		return passes[0]

	# 4. ...but if forced to add, throw in the cheapest non-trump.
	var non_trump_throws := attacks.filter(func(action): return action.card.suit != trump)
	if not non_trump_throws.is_empty():
		return _cheapest(non_trump_throws, trump)

	# 5. Give up.
	var takes := actions.filter(func(action): return action.type == "take")
	if not takes.is_empty():
		return takes[0]

	for action in actions:
		if action.type != "translate":
			return action
	return actions[0]


static func _cheapest(card_actions: Array, trump: int) -> Dictionary:
	var best: Dictionary = card_actions[0]
	for action in card_actions:
		if _card_value(action.card, trump) < _card_value(best.card, trump):
			best = action
	return best


static func _card_value(card: CardData, trump: int) -> int:
	return card.rank + (100 if card.suit == trump else 0)
