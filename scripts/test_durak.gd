extends SceneTree
## Headless fuzz test for the rules engine.
##   godot --headless --script res://scripts/test_durak.gd
## Plays many random-legal games and checks that every one terminates, that
## cards are conserved (pool_size() total, all distinct, at every step), and
## that no bug signatures show up.

const GAMES := 3000
const STEP_GUARD := 20000


## games in which a legal "deflect" was ever offered - coverage guard for the
## §8.3 tightening, not a hard assertion. If this hits 0 the restriction is
## too aggressive and deflect has become dead.
static var _deflect_seen := 0


func _initialize() -> void:
	var failures := 0
	var loser_tally := {-1: 0, 0: 0, 1: 0, 2: 0, 3: 0}
	var longest := 0

	for i in GAMES:
		var result := _play_random_game(i + 1)
		longest = maxi(longest, result.steps)
		if result.ok:
			loser_tally[result.loser] += 1
		else:
			failures += 1
			push_error("seed %d, step %d: %s" % [i + 1, result.steps, result.msg])

	print("ran %d games | failures: %d | longest game: %d steps" % [GAMES, failures, longest])
	print("loser distribution (-1 = draw): %s" % loser_tally)
	print("games where deflect was offered: %d / %d" % [_deflect_seen, GAMES])
	quit(1 if failures > 0 else 0)


var _this_game_saw_deflect := false


func _play_random_game(game_seed: int) -> Dictionary:
	seed(game_seed)
	var game := DurakGame.new(4, game_seed)
	var steps := 0
	_this_game_saw_deflect = false

	while not game.is_finished():
		steps += 1
		if steps > STEP_GUARD:
			return {ok = false, steps = steps, msg = "did not terminate"}

		var problem := _check_invariants(game)
		if problem != "":
			return {ok = false, steps = steps, msg = problem}

		var legal := game.get_all_legal_actions()
		if legal.is_empty():
			return {ok = false, steps = steps,
				msg = "no legal action, phase=%d, not finished" % game.phase}

		var saw_deflect := false
		for action in legal:
			# "take" shouldn't be legal once every attack on the table is beaten
			if action.type == "take" and _unbeaten_count(game) == 0:
				return {ok = false, steps = steps,
					msg = "take offered on a fully-beaten table"}
			if action.type == "deflect":
				saw_deflect = true
		if saw_deflect and not _this_game_saw_deflect:
			_this_game_saw_deflect = true
			_deflect_seen += 1

		var action: Dictionary = legal[randi() % legal.size()]
		if not game.apply_action(action):
			return {ok = false, steps = steps,
				msg = "apply_action rejected a legal action: %s" % action}

	var problem := _check_invariants(game)
	if problem != "":
		return {ok = false, steps = steps, msg = "post-game: " + problem}

	var sorted_order: Array = game.finish_order.duplicate()
	sorted_order.sort()
	if sorted_order != [0, 1, 2, 3]:
		return {ok = false, steps = steps,
			msg = "finish_order not a permutation: %s" % game.finish_order}

	return {ok = true, steps = steps, loser = game.loser}


func _check_invariants(game: DurakGame) -> String:
	var pool: int = game.pool_size()
	if game.total_card_count() != pool:
		return "card count = %d (pool %d)" % [game.total_card_count(), pool]

	var seen := {}
	for card in _all_cards(game):
		var key: int = card.suit * 100 + card.rank
		if seen.has(key):
			return "duplicate card %s" % card
		seen[key] = true
	if seen.size() != pool:
		return "distinct cards = %d (pool %d)" % [seen.size(), pool]

	if not game.is_finished():
		if game.defender == game.attacker:
			return "defender == attacker"
		if game.is_out[game.defender] or game.is_out[game.attacker]:
			return "an out player is attacking/defending"
	return ""


func _unbeaten_count(game: DurakGame) -> int:
	var count := 0
	for pair in game.table:
		if pair.defense == null:
			count += 1
	return count


func _all_cards(game: DurakGame) -> Array:
	var cards: Array = []
	cards.append_array(game.deck)
	cards.append_array(game.discard)
	for hand in game.hands:
		cards.append_array(hand)
	for pair in game.table:
		cards.append(pair.attack)
		if pair.defense != null:
			cards.append(pair.defense)
	return cards
