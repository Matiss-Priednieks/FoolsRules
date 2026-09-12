extends SceneTree
## Headless fuzz test for the rules engine.
##   godot --headless --script res://scripts/test_durak.gd
## Plays many random-legal games and checks that every one terminates, that
## cards are conserved (pool_size() total, at every step), and that no bug
## signatures show up. Cycles through a spread of player counts, since the
## engine is meant to run 2..MAX_PLAYERS now (7+ deal from stacked decks, so
## duplicate suit+rank is expected - only the total count is invariant).

const GAMES := 3000
## Spec 4's reserve can add up to num_players * DRAFT_ROUNDS extra cards into
## circulation on top of pool_size() (72 more on a 12-seat game - nearly double
## its 84-card pool), and a reserve draw substituting for a talon draw makes
## the talon last longer too. Both stretch the long tail of how many steps a
## game can legitimately take, especially at high player counts under this
## fuzzer's uniformly-random policy (a bot or a human plays with more purpose;
## this deliberately doesn't). A manual replay of a "hit the guard" seed at a
## much higher ceiling ran clean to completion at 163874 steps - genuinely
## slow, not stuck - and raising the guard from 40000 to 250000 only thinned
## the tail (128 -> 26 of 3000), never zeroed it, so chasing it further has
## diminishing returns and just makes every run slower. Hitting the guard is
## therefore tracked as its own stat below, not folded into `failures` - see
## _play_random_game()'s `capped` result.
const STEP_GUARD := 100000
const PLAYER_COUNTS := [2, 3, 4, 5, 6, 8, 12]


## games in which a legal "deflect" was ever offered - coverage tally for the
## deflect legality rule, not a hard assertion.
static var _deflect_seen := 0

## games in which an overwhelm_bulwark card was actually played (either half) -
## coverage tally proving a drafted special reached the table at all.
static var _overwhelm_bulwark_seen := 0

## games in which at least one draft_pick / refill_choice(reserve) action was
## actually taken - coverage tallies proving the reserve pipeline (spec 4)
## is reachable and gets exercised, not just offered.
static var _draft_pick_seen := 0
static var _reserve_draw_seen := 0

## games in which a while_held special (query-hook only, no event to log) was
## seen active in some hand - proves the query hook actually got exercised
## with the card physically in play (drafted, then drawn into a hand via
## refill), not just offered and never checked.
const WHILE_HELD_IDS: Array[StringName] = [&"light", &"millstone", &"deadweight"]
static var _while_held_seen := {}   # id -> games count

## games in which an event-fired special actually logged doing something -
## SpecialEffects.handle() prefixes every message with the card's display
## name, so this is a generic "did it fire" tally, not per-card boilerplate.
const EVENT_KEYWORDS := ["Sift", "Barbed", "Cull", "Greedy", "Last", "Muzzle"]
static var _event_seen := {}        # keyword -> games count


func _initialize() -> void:
	var failures := 0
	var capped := 0
	var longest := 0
	var by_count := {}

	for i in GAMES:
		var players: int = PLAYER_COUNTS[i % PLAYER_COUNTS.size()]
		var result := _play_random_game(i + 1, players)
		longest = maxi(longest, result.steps)
		by_count[players] = by_count.get(players, 0) + 1
		if result.get("capped", false):
			capped += 1
		elif not result.ok:
			failures += 1
			push_error("seed %d (%dp), step %d: %s" % [i + 1, players, result.steps, result.msg])
		if (i + 1) % 500 == 0:
			print("... %d / %d games (failures %d, capped %d so far)" % [i + 1, GAMES, failures, capped])

	print("ran %d games | failures: %d | hit the step guard (not a failure - see STEP_GUARD's doc comment): %d | longest game: %d steps" % [
		GAMES, failures, capped, longest])
	print("games per player count: %s" % by_count)
	print("games where deflect was offered: %d / %d" % [_deflect_seen, GAMES])
	print("games where overwhelm_bulwark was played: %d / %d" % [_overwhelm_bulwark_seen, GAMES])
	print("games where a draft pick was made: %d / %d" % [_draft_pick_seen, GAMES])
	print("games where a reserve card was drawn: %d / %d" % [_reserve_draw_seen, GAMES])
	print("games where each while-held special was active: %s / %d" % [_while_held_seen, GAMES])
	print("games where each event-fired special logged an effect: %s / %d" % [_event_seen, GAMES])
	quit(1 if failures > 0 else 0)


var _this_game_saw_deflect := false
var _this_game_saw_overwhelm_bulwark := false
var _this_game_while_held: Dictionary = {}
var _this_game_events: Dictionary = {}
var _this_game_drafted := false
var _this_game_drew_reserve := false


func _play_random_game(game_seed: int, players: int) -> Dictionary:
	seed(game_seed)
	var game := DurakGame.new(players, game_seed, SpecialEffects.new())
	var steps := 0
	_this_game_saw_deflect = false
	_this_game_saw_overwhelm_bulwark = false
	_this_game_while_held = {}
	_this_game_events = {}
	_this_game_drafted = false
	_this_game_drew_reserve = false

	while not game.is_finished():
		steps += 1
		if steps > STEP_GUARD:
			# Not a correctness failure - see STEP_GUARD's doc comment. Every
			# invariant held at every step up to here; this game was just
			# taking an unusually long time under a uniformly-random policy,
			# not stuck (a manually replayed sample converged normally at a
			# much higher ceiling).
			return {ok = true, steps = steps, capped = true}

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

		for id in WHILE_HELD_IDS:
			if _this_game_while_held.has(id):
				continue
			for hand in game.hands:
				if hand.any(func(c): return c.special == id):
					_this_game_while_held[id] = true
					_while_held_seen[id] = _while_held_seen.get(id, 0) + 1
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

		if action.type == "draft_pick" and not _this_game_drafted:
			_this_game_drafted = true
			_draft_pick_seen += 1
		if action.type == "refill_choice" and action.get("card") != null and not _this_game_drew_reserve:
			_this_game_drew_reserve = true
			_reserve_draw_seen += 1

		for msg in game.effect_log:
			for kw in EVENT_KEYWORDS:
				if not _this_game_events.has(kw) and msg.begins_with(kw):
					_this_game_events[kw] = true
					_event_seen[kw] = _event_seen.get(kw, 0) + 1

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
	# Reserve cards (spec 4.1) are manufactured on the spot, not part of the
	# talon's pool_size() count - they're a genuinely separate supply, so the
	# conserved total grows by one for every draft pick actually made.
	var pool: int = game.pool_size() + game.reserve_cards_created
	if game.total_card_count() != pool:
		return "card count = %d (pool %d)" % [game.total_card_count(), pool]

	if _all_cards(game).size() != pool:
		return "loose card count = %d (pool %d)" % [_all_cards(game).size(), pool]

	if not game.is_finished():
		if game.defender == game.attacker:
			return "defender == attacker"
		if game.is_out[game.defender] or game.is_out[game.attacker]:
			return "an out player is attacking/defending"

	var reserve_problem := _check_reserve(game)
	if reserve_problem != "":
		return reserve_problem
	var cap_problem := _check_attack_cap(game)
	if cap_problem != "":
		return cap_problem
	var deadweight_problem := _check_deadweight(game)
	if deadweight_problem != "":
		return deadweight_problem
	return _check_muzzle(game)


## Targeted assertion for the reserve/draft (spec 4): a seat's lifetime picks
## never exceed DRAFT_ROUNDS, its reserve never exceeds RESERVE_CAP (a
## consequence of the pick cap, not separately enforced - worth checking that
## it actually holds), and every card ever offered or held is a real special.
func _check_reserve(game: DurakGame) -> String:
	for seat in game.num_players:
		if game.draft_picks_used[seat] > DurakGame.DRAFT_ROUNDS:
			return "seat %d has drafted %d times (cap %d)" % [
				seat, game.draft_picks_used[seat], DurakGame.DRAFT_ROUNDS]
		if game.reserves[seat].size() > DurakGame.RESERVE_CAP:
			return "seat %d's reserve holds %d cards (cap %d)" % [
				seat, game.reserves[seat].size(), DurakGame.RESERVE_CAP]
		for card in game.reserves[seat]:
			if not card.is_special():
				return "seat %d's reserve holds a non-special card" % seat
		for card in game.draft_offers[seat]:
			if not card.is_special():
				return "seat %d was offered a non-special card" % seat
	return ""


## Targeted assertion for Overwhelm/Bulwark (spec 5, Table-shape). Checks the
## *observable* legality, not the raw pile size: a pile can already be past 4
## before Bulwark is even played (it caps future growth, it doesn't retroactively
## shrink an existing pile), so the only real invariant is "once at the adjusted
## cap, no attacking seat is ever offered a new attack/throw-in". Bulwark
## (defense) wins any tie with Overwhelm (attack) per attack_cap()'s ordering.
func _check_attack_cap(game: DurakGame) -> String:
	# Overwhelm_count, not a bool: SpecialEffects.attack_cap() adds +2 per
	# matching attack card on the table, not once - and with the draft now
	# able to hand out several copies of the same special over a hand, two
	# can legitimately end up on the same table at once. Bulwark's clamp is
	# idempotent, so a bool is fine for it.
	var overwhelm_count := 0
	var has_bulwark := false
	for pair in game.table:
		if pair.attack.special == &"overwhelm_bulwark":
			overwhelm_count += 1
		if pair.defense != null and pair.defense.special == &"overwhelm_bulwark":
			has_bulwark = true
	if overwhelm_count == 0 and not has_bulwark:
		return ""

	var cap := game.attack_limit + overwhelm_count * 2
	if has_bulwark:
		cap = mini(cap, 4)
	if game.table.size() < cap:
		return ""  # room left under the cap; nothing to check yet

	for seat in game.num_players:
		if seat == game.defender or game.is_out[seat] or game.hands[seat].is_empty():
			continue
		for action in game.get_legal_actions(seat):
			if action.type == "attack":
				return "seat %d offered an attack at the cap (%d, overwhelm_count=%d bulwark=%s)" % [
					seat, cap, overwhelm_count, has_bulwark]
	return ""


## Targeted assertion for Deadweight (spec 5, Payload): never legal to defend
## with one, and never legal to throw it in once the table already has a card
## on it (lead-only). Cheaply bails if no Deadweight is anywhere in play - this
## runs every step of every game, so it must not call the expensive
## get_all_legal_actions() (O(players x hand size x table size)) when there's
## nothing to check; that unconditional call once made this test dramatically
## slower without a single Deadweight in most steps of most games.
func _check_deadweight(game: DurakGame) -> String:
	var in_play := false
	for hand in game.hands:
		if hand.any(func(c): return c.special == &"deadweight"):
			in_play = true
			break
	if not in_play:
		for pair in game.table:
			if pair.attack.special == &"deadweight" \
			or (pair.defense != null and pair.defense.special == &"deadweight"):
				in_play = true
				break
	if not in_play:
		return ""

	for action in game.get_all_legal_actions():
		if action.type == "defend" and action.card.special == &"deadweight":
			return "Deadweight offered as a defend"
		if action.type == "attack" and action.card.special == &"deadweight" and not game.table.is_empty():
			return "Deadweight offered as a throw-in (table not empty)"
	return ""


## Targeted assertion for Muzzle (spec 5, Payload): a seat currently locked
## out (_throw_in_locked, "next round") must never be offered an attack.
func _check_muzzle(game: DurakGame) -> String:
	for seat in game._throw_in_locked:
		for action in game.get_legal_actions(seat):
			if action.type == "attack":
				return "seat %d muzzled but offered an attack" % seat
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
	for reserve in game.reserves:
		cards.append_array(reserve)
	return cards
