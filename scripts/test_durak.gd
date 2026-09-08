extends SceneTree
## Headless fuzz test for the rules engine.
##   godot --headless --script res://scripts/test_durak.gd
## Plays many random-legal games and checks that every one terminates, that
## cards are conserved (pool_size() total, at every step), and that no bug
## signatures show up. Cycles through a spread of player counts, since the
## engine is meant to run 2..MAX_PLAYERS now (7+ deal from stacked decks, so
## duplicate suit+rank is expected - only the total count is invariant).

const GAMES := 3000
const STEP_GUARD := 40000
const PLAYER_COUNTS := [2, 3, 4, 5, 6, 8, 12]


## games in which a legal "deflect" was ever offered - coverage tally for the
## deflect legality rule, not a hard assertion.
static var _deflect_seen := 0


func _initialize() -> void:
	var failures := 0
	var longest := 0
	var by_count := {}

	for i in GAMES:
		var players: int = PLAYER_COUNTS[i % PLAYER_COUNTS.size()]
		var result := _play_random_game(i + 1, players)
		longest = maxi(longest, result.steps)
		by_count[players] = by_count.get(players, 0) + 1
		if not result.ok:
			failures += 1
			push_error("seed %d (%dp), step %d: %s" % [i + 1, players, result.steps, result.msg])

	print("ran %d games | failures: %d | longest game: %d steps" % [GAMES, failures, longest])
	print("games per player count: %s" % by_count)
	print("games where deflect was offered: %d / %d" % [_deflect_seen, GAMES])
	quit(1 if failures > 0 else 0)


var _this_game_saw_deflect := false


func _play_random_game(game_seed: int, players: int) -> Dictionary:
	seed(game_seed)
	var game := DurakGame.new(players, game_seed)
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
	var expected: Array = range(game.num_players)
	if sorted_order != expected:
		return {ok = false, steps = steps,
			msg = "finish_order not a permutation of %s: %s" % [expected, game.finish_order]}

	return {ok = true, steps = steps, loser = game.loser}


func _check_invariants(game: DurakGame) -> String:
	var pool: int = game.pool_size()
	if game.total_card_count() != pool:
		return "card count = %d (pool %d)" % [game.total_card_count(), pool]

	if _all_cards(game).size() != pool:
		return "loose card count = %d (pool %d)" % [_all_cards(game).size(), pool]

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
