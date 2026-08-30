class_name Bot
## Dumb heuristic policy for the AI seats. Phase 4 will make this smarter.
## Notes: bots never translate yet, and they prefer passing over throwing in.

## Returns one legal action for whichever bot seat should act now, or {} if the
## only legal actions belong to `exclude_player` (the human).
static func pick(game: DurakGame, exclude_player: int = -1) -> Dictionary:
	var acts: Array[Dictionary] = []
	for p in game.num_players:
		if p != exclude_player:
			acts.append_array(game.get_legal_actions(p))
	if acts.is_empty():
		return {}

	var trump: int = game.trump_suit

	# 1. Beat the current attack with the cheapest card that does the job.
	var defends := acts.filter(func(a): return a.type == "defend")
	if not defends.is_empty():
		defends.sort_custom(func(a, b): return _val(a.card, trump) < _val(b.card, trump))
		return defends[0]

	var attacks := acts.filter(func(a): return a.type == "attack")

	# 2. Opening the bout: lead the cheapest card (no pass is offered here).
	if game.table.is_empty() and not attacks.is_empty():
		attacks.sort_custom(func(a, b): return _val(a.card, trump) < _val(b.card, trump))
		return attacks[0]

	# 3. Otherwise rather pass than commit cards...
	var passes := acts.filter(func(a): return a.type == "pass")
	if not passes.is_empty():
		return passes[0]

	# 4. ...but if we must add, throw in the cheapest non-trump.
	var cheap := attacks.filter(func(a): return a.card.suit != trump)
	if not cheap.is_empty():
		cheap.sort_custom(func(a, b): return _val(a.card, trump) < _val(b.card, trump))
		return cheap[0]

	# 5. Give up.
	var takes := acts.filter(func(a): return a.type == "take")
	if not takes.is_empty():
		return takes[0]

	for a in acts:
		if a.type != "translate":
			return a
	return acts[0]


static func _val(c: CardData, trump: int) -> int:
	return c.rank + (100 if c.suit == trump else 0)
