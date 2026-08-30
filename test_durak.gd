extends SceneTree
## Headless fuzz test for the rules engine.
##   godot --headless --script res://test_durak.gd
## Plays many random-legal games and checks that every one terminates and that
## cards are conserved (36 at all times, all distinct).

const GAMES := 3000
const STEP_GUARD := 20000


func _initialize() -> void:
	var failures := 0
	var loser_tally := {-1: 0, 0: 0, 1: 0, 2: 0, 3: 0}
	var max_steps := 0

	for i in GAMES:
		var r := _play_random_game(i + 1)
		max_steps = maxi(max_steps, r.steps)
		if r.ok:
			loser_tally[r.loser] += 1
		else:
			failures += 1
			push_error("seed %d, step %d: %s" % [i + 1, r.steps, r.msg])

	print("ran %d games | failures: %d | longest game: %d steps" % [GAMES, failures, max_steps])
	print("loser distribution (‑1 = draw): %s" % loser_tally)
	quit(1 if failures > 0 else 0)


func _play_random_game(game_seed: int) -> Dictionary:
	seed(game_seed)
	var g := DurakGame.new(4, game_seed)
	var steps := 0

	while not g.is_finished():
		steps += 1
		if steps > STEP_GUARD:
			return {ok = false, steps = steps, msg = "did not terminate"}

		var bad := _check_invariants(g)
		if bad != "":
			return {ok = false, steps = steps, msg = bad}

		var pool := g.get_all_legal_actions()
		if pool.is_empty():
			return {ok = false, steps = steps,
				msg = "no legal action, phase=%d, not finished" % g.phase}

		# bug signature: everything is beaten but the only move is the defender
		# taking their own completed defense (attackers can't pass/throw in)
		var only_self_take := pool.all(func(a): return a.type == "take")
		if only_self_take and _unbeaten(g) == 0:
			return {ok = false, steps = steps,
				msg = "defender forced to take a fully-beaten table"}

		var action: Dictionary = pool[randi() % pool.size()]
		if not g.apply_action(action):
			return {ok = false, steps = steps,
				msg = "apply_action rejected a legal action: %s" % action}

	var bad := _check_invariants(g)
	if bad != "":
		return {ok = false, steps = steps, msg = "post-game: " + bad}

	var fo: Array = g.finish_order.duplicate()
	fo.sort()
	if fo != [0, 1, 2, 3]:
		return {ok = false, steps = steps, msg = "finish_order not a permutation: %s" % g.finish_order}

	return {ok = true, steps = steps, loser = g.loser}


func _check_invariants(g: DurakGame) -> String:
	if g.total_card_count() != 36:
		return "card count = %d" % g.total_card_count()

	var seen := {}
	for c in _all_cards(g):
		var key: int = c.suit * 100 + c.rank
		if seen.has(key):
			return "duplicate card %s" % c
		seen[key] = true
	if seen.size() != 36:
		return "distinct cards = %d" % seen.size()

	if not g.is_finished():
		if g.defender == g.attacker:
			return "defender == attacker"
		if g.is_out[g.defender] or g.is_out[g.attacker]:
			return "an out player is attacking/defending"
	return ""


func _unbeaten(g: DurakGame) -> int:
	var n := 0
	for pair in g.table:
		if pair.defense == null:
			n += 1
	return n


func _all_cards(g: DurakGame) -> Array:
	var out: Array = []
	out.append_array(g.deck)
	out.append_array(g.discard)
	for h in g.hands:
		out.append_array(h)
	for pair in g.table:
		out.append(pair.attack)
		if pair.defense != null:
			out.append(pair.defense)
	return out
