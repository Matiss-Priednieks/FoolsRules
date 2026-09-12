class_name DurakGame
extends RefCounted
## Headless perevodnoy (podkidnoy) Durak. No rendering, no input, no AI.
##
## The view and the bots both drive it the same way:
##   for action in game.get_all_legal_actions(): ...   # what can happen now
##   game.apply_action(action)                          # do one of them
##
## Contract: the `card` inside an action must be the exact CardData instance
## returned by get_legal_actions() (identity matters, hands hold references).
##
## The attacking side may lay down at most _attack_cap(defender) cards this bout
## (default: the defender's whole hand size at bout start - no 6-card ceiling,
## spec 3.6). Table-shape specials override the cap.
##
## Roguelike layer (spec 3.1, 9): special cards are ordinary ranked cards with a
## CardData.special id. The engine stays vanilla unless `_effects` is set; when
## it is, _fire() dispatches the trigger-point events below and the _*_target /
## _*_cap query hooks let "while held" modifiers change refill counts and caps.
##
## Known simplifications vs. full house rules:
##   - a deflect cannot bounce back onto the original attacker
##   - 5-6 player pools (spec 3.5) need a base deck larger than 36; not built

signal state_changed
signal game_over(loser: int)  # loser == -1 means everyone emptied at once (draw)

const HAND_SIZE := 6      # the refill target for a plain hand; _refill_target() may raise/lower it
const MIN_RANK := 6       # a 4-or-fewer-player game uses the classic 36-card deck (6..A)
const MIN_RANK_BIG := 2   # 5+ players: full 2..A ranks, and more than one deck if the pool needs it
const MAX_PLAYERS := 24   # the hard ceiling; the board and balance are only really tuned to ~6

enum Phase { ATTACK, DEFEND, TAKING, GAME_OVER }

## Special-card effect trigger points (spec 9). Event triggers fire through
## _fire() at the moment named; "while held" modifiers are queried instead, via
## _refill_target() / _attack_cap().
enum Trigger {
	ON_REFILL,           # a seat is about to draw its refill      ctx = {seat}
	ON_PICKUP,           # a seat took the table into its hand      ctx = {seat, cards}
	ON_DEFENSE_SUCCESS,  # a bout resolved, defender beat it all    ctx = {defender}
	ON_DEFENSE_PLAYED,   # a defend card was placed                 ctx = {seat, card, target}
	ON_THROW_IN,         # an attack/throw-in card was placed       ctx = {seat, card}
	ON_ATTACK_END,       # a bout is being halted early by a card   ctx = {defender, beaten}
}

var num_players: int
var hands: Array[Array] = []      # hands[seat] : Array[CardData]
var deck: Array[CardData] = []    # talon; draw from the back. deck[0] is the trump card.
var discard: Array[CardData] = []
var trump_card: CardData          # kept for display after it is drawn
var trump_suit: int

# Current bout
var table: Array[Dictionary] = []  # [{attack: CardData, defense: CardData|null}, ...]
var attacker: int                  # primary attacker (opens the bout, refills first)
var defender: int
var phase: int = Phase.ATTACK
var attack_limit: int              # max cards on the table this bout; set when the defender is set
var passed: Dictionary = {}        # seat -> true, cleared on every change to the table

var is_out: Array[bool] = []       # finished the game (empty hand, empty talon)
var finish_order: Array[int] = []  # seats in the order they went out; the durak is last
var loser: int = -1
var seed_used: int

## Set to a SpecialEffects instance to switch the roguelike layer on. null =
## pure vanilla: _fire() is a no-op and the query hooks return plain values.
## Passed into _init(), not assigned after, because specials are physically
## part of the deck (spec 3.1) - _build_and_deal() needs to know before it runs.
var effects: Object = null

var _rng := RandomNumberGenerator.new()


func _init(players: int = 4, game_seed: int = 0, game_effects: Object = null) -> void:
	num_players = clampi(players, 2, MAX_PLAYERS)
	seed_used = game_seed if game_seed != 0 else \
		int(Time.get_unix_time_from_system() * 1000.0) & 0x7fffffff
	_rng.seed = seed_used
	effects = game_effects
	_build_and_deal()


# ------------------------------------------------------------------ public query

func get_legal_actions(seat: int) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	if phase == Phase.GAME_OVER or is_out[seat]:
		return actions

	if seat == defender:
		if phase == Phase.DEFEND:
			for slot in table.size():
				if table[slot].defense == null:
					for card in hands[seat]:
						if card.beats(table[slot].attack, trump_suit):
							actions.append({type = "defend", player = seat, card = card, target = slot})
			if _can_deflect():
				var lead_rank: int = table[0].attack.rank
				for card in hands[seat]:
					if card.rank == lead_rank:
						actions.append({type = "deflect", player = seat, card = card})
			# "take" only means something while a card is still unbeaten; once the
			# defence is complete the bout just waits for the attackers to pass
			if _unbeaten_count() > 0:
				actions.append({type = "take", player = seat})
		return actions

	# attacking side: everyone who is not the defender
	if table.is_empty():
		# opening the bout: only the primary attacker, one card to start
		if seat == attacker and _can_add_attack(seat):
			for card in hands[seat]:
				actions.append({type = "attack", player = seat, card = card})
		return actions

	# bout in progress (defender is beating cards off or taking): throw in a card
	# of a rank already on the table, or pass
	if _can_add_attack(seat):
		var ranks_on_table := _table_ranks()
		for card in hands[seat]:
			if card.rank in ranks_on_table:
				actions.append({type = "attack", player = seat, card = card})
	if not passed.has(seat) and not hands[seat].is_empty():
		actions.append({type = "pass", player = seat})
	return actions


func get_all_legal_actions() -> Array[Dictionary]:
	var all_actions: Array[Dictionary] = []
	for seat in num_players:
		all_actions.append_array(get_legal_actions(seat))
	return all_actions


func talon_count() -> int:
	return deck.size()


func is_finished() -> bool:
	return phase == Phase.GAME_OVER


func total_card_count() -> int:  # invariant helper: always == pool_size()
	var total := deck.size() + discard.size()
	for pair in table:
		total += 1
		if pair.defense != null:
			total += 1
	for hand in hands:
		total += hand.size()
	return total


# ------------------------------------------------------------------ public apply

func apply_action(action: Dictionary) -> bool:
	if phase == Phase.GAME_OVER:
		return false
	if not _is_legal(action):
		return false
	match action.type:
		"attack": _apply_attack(action.player, action.card)
		"defend": _apply_defend(action.player, action.card, action.target)
		"deflect": _apply_deflect(action.player, action.card)
		"take": _apply_take(action.player)
		"pass": _apply_pass(action.player)
		_: return false
	return true


# ------------------------------------------------------------------ setup

func _build_and_deal() -> void:
	for seat in num_players:
		hands.append([] as Array[CardData])
		is_out.append(false)

	# spec 3.5: cards in circulation set the match clock (pool_size = 6/player + 12).
	# <=4 players: the classic single 36-card deck. 5+: full 2..A ranks, and as
	# many stacked decks as the pool needs (so 7+ players draw with duplicates).
	var min_rank := MIN_RANK if num_players <= 4 else MIN_RANK_BIG
	var per_deck := 4 * (15 - min_rank)
	var decks := maxi(1, ceili(float(pool_size()) / per_deck))
	for _copy in decks:
		for suit in 4:
			for rank in range(min_rank, 15):
				deck.append(CardData.new(suit, rank))
	_shuffle(deck)
	if deck.size() > pool_size():
		deck.resize(pool_size())
	if effects != null:
		_debug_seed_specials()

	trump_card = deck[0]
	trump_suit = trump_card.suit

	for _round in HAND_SIZE:
		for seat in num_players:
			hands[seat].append(deck.pop_back())

	attacker = _find_first_attacker()
	defender = _next_active(attacker)
	_set_attack_limit()


## spec 3.5: 6 per player plus a 12-card buffer.
func pool_size() -> int:
	return 6 * num_players + 12


## TEMPORARY stand-in for the real acquisition path (spec 4: private reserve +
## staggered draft, neither built yet). Tags one card so a special is actually
## reachable for manual/fuzz testing while a card's behaviour is being built.
## Delete this once the draft/reserve exists.
func _debug_seed_specials() -> void:
	deck[deck.size() - 1].special = &"overwhelm_bulwark"


func _set_attack_limit() -> void:
	attack_limit = _attack_cap(defender)


func _shuffle(cards: Array) -> void:
	for i in range(cards.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var swap: Variant = cards[i]
		cards[i] = cards[j]
		cards[j] = swap


func _find_first_attacker() -> int:
	var best_seat := 0
	var best_rank := 99
	for seat in num_players:
		for card in hands[seat]:
			if card.suit == trump_suit and card.rank < best_rank:
				best_rank = card.rank
				best_seat = seat
	return best_seat


# ------------------------------------------------------------------ rules helpers

func _next_active(after_seat: int) -> int:
	var seat := (after_seat + 1) % num_players
	while is_out[seat] and seat != after_seat:
		seat = (seat + 1) % num_players
	return seat


func _active_count() -> int:
	var count := 0
	for finished in is_out:
		if not finished:
			count += 1
	return count


func _unbeaten_count() -> int:
	var count := 0
	for pair in table:
		if pair.defense == null:
			count += 1
	return count


func _table_ranks() -> Array:
	var ranks := {}
	for pair in table:
		ranks[pair.attack.rank] = true
		if pair.defense != null:
			ranks[pair.defense.rank] = true
	return ranks.keys()


func _can_add_attack(seat: int) -> bool:
	if hands[seat].is_empty():
		return false
	return table.size() < _current_attack_cap()


## `attack_limit` is frozen once at bout start (see _set_attack_limit) so it
## never double-counts a card the defender has already spent defending. A
## table-shape special played mid-bout (Overwhelm as an attack, Bulwark as a
## defense) needs to take effect the instant it lands though, so this re-derives
## the *live* cap from it on every call by rescanning the table - cheap, the
## table is always small - instead of ever re-touching hand size.
func _current_attack_cap() -> int:
	if effects == null:
		return attack_limit
	return effects.attack_cap(defender, self, attack_limit)


func _can_deflect() -> bool:
	# Standard perevod: you can pass the whole pile on as long as every card on
	# the table is the lead rank and nothing has been beaten yet - same-rank
	# throw-ins (from anyone) don't lock it, a defence or an off-rank card does.
	# The off-rank check also handles a future special that lets non-matching
	# cards be thrown in: that card makes the pile un-passable. The next player
	# must be able to face the enlarged attack. A matching-rank card in hand is
	# checked by the caller; Riveted (future) will veto via a query hook.
	if phase != Phase.DEFEND or table.is_empty():
		return false
	var lead_rank: int = table[0].attack.rank
	for pair in table:
		if pair.defense != null or pair.attack.rank != lead_rank:
			return false
	var new_defender := _next_active(defender)
	if new_defender == defender or new_defender == attacker:
		return false
	return hands[new_defender].size() >= table.size() + 1


# ------------------------------------------------------------------ action apply

func _apply_attack(seat: int, card: CardData) -> void:
	hands[seat].erase(card)
	table.append({attack = card, defense = null})
	passed.clear()
	if phase == Phase.ATTACK:
		phase = Phase.DEFEND
	state_changed.emit()
	_fire(Trigger.ON_THROW_IN, {seat = seat, card = card})
	# A throw-in can be the last possible attack (hand emptied, or table full).
	if phase == Phase.TAKING:
		_maybe_resolve_taking()
	else:
		_maybe_resolve_defense()


func _apply_defend(seat: int, card: CardData, target: int) -> void:
	hands[seat].erase(card)
	table[target].defense = card
	passed.clear()
	state_changed.emit()
	_fire(Trigger.ON_DEFENSE_PLAYED, {seat = seat, card = card, target = target})
	_maybe_resolve_defense()


func _apply_deflect(seat: int, card: CardData) -> void:
	hands[seat].erase(card)
	table.append({attack = card, defense = null})
	defender = _next_active(defender)  # old defender is now just an attacker
	_set_attack_limit()                # cap now follows the new defender's hand
	passed.clear()
	state_changed.emit()
	_fire(Trigger.ON_THROW_IN, {seat = seat, card = card})


func _apply_take(seat: int) -> void:
	phase = Phase.TAKING
	passed.clear()
	state_changed.emit()
	_maybe_resolve_taking()


func _apply_pass(seat: int) -> void:
	passed[seat] = true
	state_changed.emit()
	if phase == Phase.TAKING:
		_maybe_resolve_taking()
	else:
		_maybe_resolve_defense()


# ------------------------------------------------------------------ bout resolution

func _maybe_resolve_defense() -> void:
	if phase != Phase.DEFEND or _unbeaten_count() > 0:
		return
	if _someone_may_still_attack():
		return
	_resolve_bout(false)


func _maybe_resolve_taking() -> void:
	if _someone_may_still_attack():
		return
	_resolve_bout(true)


func _someone_may_still_attack() -> bool:
	for seat in num_players:
		if seat == defender or is_out[seat] or hands[seat].is_empty():
			continue
		if not passed.has(seat) and _can_add_attack(seat):
			return true
	return false


func _resolve_bout(defender_took: bool) -> void:
	var taken: Array[CardData] = []
	for pair in table:
		var destination: Array = hands[defender] if defender_took else discard
		destination.append(pair.attack)
		taken.append(pair.attack)
		if pair.defense != null:
			destination.append(pair.defense)
			taken.append(pair.defense)
	table.clear()
	passed.clear()

	if defender_took:
		_fire(Trigger.ON_PICKUP, {seat = defender, cards = taken})
	else:
		_fire(Trigger.ON_DEFENSE_SUCCESS, {defender = defender})

	var next_attacker := _next_active(defender) if defender_took else defender
	_refill()
	_update_out()

	if _active_count() <= 1:
		phase = Phase.GAME_OVER
		loser = _last_active()
		if loser >= 0 and not finish_order.has(loser):
			finish_order.append(loser)  # the durak, last
		state_changed.emit()
		game_over.emit(loser)
		return

	if is_out[next_attacker]:
		next_attacker = _next_active(next_attacker)
	attacker = next_attacker
	defender = _next_active(attacker)
	_set_attack_limit()
	phase = Phase.ATTACK
	state_changed.emit()


func _refill() -> void:
	var refill_order: Array[int] = []
	var seat := attacker
	for _step in num_players:
		if not is_out[seat]:
			refill_order.append(seat)
		seat = (seat + 1) % num_players
	refill_order.erase(defender)          # defender always refills last
	if not is_out[defender]:
		refill_order.append(defender)
	for refilling_seat in refill_order:
		_fire(Trigger.ON_REFILL, {seat = refilling_seat})
		while hands[refilling_seat].size() < _refill_target(refilling_seat) and not deck.is_empty():
			hands[refilling_seat].append(deck.pop_back())


func _update_out() -> void:
	if not deck.is_empty():
		return
	for seat in num_players:
		if not is_out[seat] and hands[seat].is_empty():
			is_out[seat] = true
			finish_order.append(seat)


func _last_active() -> int:
	for seat in num_players:
		if not is_out[seat]:
			return seat
	return -1


# ------------------------------------------------------------ special-card hooks
# All no-ops while `effects` is null (vanilla). Wired now so the call sites exist
# and are proven to fire at the right moments; SpecialEffects fills in behaviour.

## Every special card currently in a hand or on the table gets a chance to react
## to `trigger`. Discard and the undrawn talon are inert (spec 8.1 / 4.5).
func _fire(trigger: int, ctx: Dictionary) -> void:
	if effects == null:
		return
	for card in _specials_in_play():
		effects.handle(card.special, trigger, self, ctx)


func _specials_in_play() -> Array[CardData]:
	var out: Array[CardData] = []
	for hand in hands:
		for card in hand:
			if card.is_special():
				out.append(card)
	for pair in table:
		if pair.attack.is_special():
			out.append(pair.attack)
		if pair.defense != null and pair.defense.is_special():
			out.append(pair.defense)
	return out


## How many cards `seat` refills to this round. Default HAND_SIZE; Light lowers
## it, Millstone/Barbed raise it (spec 5, Economy).
func _refill_target(seat: int) -> int:
	if effects == null:
		return HAND_SIZE
	return effects.refill_target(seat, self, HAND_SIZE)


## Cap on cards the attacking side may lay down against `defender` this bout.
## Default: the defender's whole hand, no ceiling (spec 3.6). Bulwark lowers it,
## Overwhelm raises it.
func _attack_cap(defender_seat: int) -> int:
	var base := hands[defender_seat].size()
	if effects == null:
		return base
	return effects.attack_cap(defender_seat, self, base)


# ------------------------------------------------------------------ validation

func _is_legal(action: Dictionary) -> bool:
	if not action.has("type") or not action.has("player"):
		return false
	for candidate in get_legal_actions(action.player):
		if candidate.type != action.type:
			continue
		if candidate.get("card") != action.get("card"):
			continue
		if candidate.get("target", -1) != action.get("target", -1):
			continue
		return true
	return false
