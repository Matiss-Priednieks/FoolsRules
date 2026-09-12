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

## games in which the debug-seeded overwhelm_bulwark card was actually played
## (either half) - coverage tally proving the special reached the table at
## all, since _debug_seed_specials() is the only source of one right now.
static var _overwhelm_bulwark_seen := 0


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
	print("games where overwhelm_bulwark was played: %d / %d" % [_overwhelm_bulwark_seen, GAMES])
	quit(1 if failures > 0 else 0)


var _this_game_saw_deflect := false
var _this_game_saw_overwhelm_bulwark := false


func _play_random_game(game_seed: int, players: int) -> Dictionary:
	seed(game_seed)
	var game := DurakGame.new(players, game_seed, SpecialEffects.new())
	var steps := 0
	_this_game_saw_deflect = false
	_this_game_saw_overwhelm_bulwark = false

	while not game.is_finished():
		steps += 1
		if steps > STEP_GUARD:
			return {ok = false, steps = steps, msg = "did not terminate"}

		var problem := _check_invariants(game)
		if problem != "":
			return {ok = false, steps = steps, msg = problem}

		if not _this_game_saw_overwhelm_bulwark:
			for pair in game.table:
				if pair.attack.special == &"overwhelm_bulwark" \
				or (pair.defense != null and pair.defense.special == &"overwhelm_bulwark"):
					_this_game_saw_overwhelm_bulwark = true
					_overwhelm_bulwark_seen += 1
					break

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

	return _check_attack_cap(game)


## Targeted assertion for Overwhelm/Bulwark (spec 5, Table-shape). Checks the
## *observable* legality, not the raw pile size: a pile can already be past 4
## before Bulwark is even played (it caps future growth, it doesn't retroactively
## shrink an existing pile), so the only real invariant is "once at the adjusted
## cap, no attacking seat is ever offered a new attack/throw-in". Bulwark
## (defense) wins any tie with Overwhelm (attack) per attack_cap()'s ordering.
func _check_attack_cap(game: DurakGame) -> String:
	var has_overwhelm := false
	var has_bulwark := false
	for pair in game.table:
		if pair.attack.special == &"overwhelm_bulwark":
			has_overwhelm = true
		if pair.defense != null and pair.defense.special == &"overwhelm_bulwark":
			has_bulwark = true
	if not has_overwhelm and not has_bulwark:
		return ""

	var cap := game.attack_limit + (2 if has_overwhelm else 0)
	if has_bulwark:
		cap = mini(cap, 4)
	if game.table.size() < cap:
		return ""  # room left under the cap; nothing to check yet

	for seat in game.num_players:
		if seat == game.defender or game.is_out[seat] or game.hands[seat].is_empty():
			continue
		for action in game.get_legal_actions(seat):
			if action.type == "attack":
				return "seat %d offered an attack at the cap (%d, overwhelm=%s bulwark=%s)" % [
					seat, cap, has_overwhelm, has_bulwark]
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
