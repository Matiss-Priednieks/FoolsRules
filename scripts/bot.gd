class_name Bot
## Dumb heuristic policy for the AI seats. Phase 4 will make this smarter.
## For now bots never deflect, and they would rather pass than throw a card in.

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

	# 0. Ambient administrative choices (spec 4) cost nothing to resolve and
	# must not get starved out by an always-busy table - draft picks are
	# available alongside every other action a seat can take, so with enough
	# bots that always have *something* tactical to do, one's own pick could
	# otherwise never bubble up through the priority chain below.
	var drafts := actions.filter(func(action): return action.type == "draft_pick")
	if not drafts.is_empty():
		# Any randomness here MUST go through game._rng, not global random -
		# bots run identically on every multiplayer peer from the same replayed
		# action stream, and reserve strategy is deferred smartness (see the
		# class doc), so a uniform random pick is the honest placeholder.
		return drafts[game._rng.randi_range(0, drafts.size() - 1)]
	var refill_choices := actions.filter(func(action): return action.type == "refill_choice")
	if not refill_choices.is_empty():
		for choice in refill_choices:
			if choice.get("card") == null:  # always draw from the talon for now
				return choice
		return refill_choices[0]

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
		if action.type != "deflect":
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
