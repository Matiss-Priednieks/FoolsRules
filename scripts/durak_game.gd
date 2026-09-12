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
## CardData.special id. The engine stays vanilla unless `effects` is set; when
## it is, _fire() dispatches the trigger-point events below to SpecialEffects,
## and the _*_target / _*_cap / _can_play_* query hooks let a held or in-play
## special change refill counts, attack caps, and play legality.
##
## Reserve (spec 4): each seat has a private magazine of specials, drafted one
## at a time (draft_pick, ambient - available whenever offered, alongside
## whatever else that seat can currently do) and drawn into a hand only via
## refill, in place of a talon card (refill_choice, spec 4.1). Reserve cards
## are manufactured on the spot, not part of pool_size()'s count - they're a
## genuinely separate supply, which is the only way "may come from the talon
## OR your reserve" means anything. See _generate_draft_offers()/_advance_refill().
##
## Known simplifications vs. full house rules:
##   - a deflect cannot bounce back onto the original attacker
##   - the draft pool only offers ids SpecialEffects actually implements (8 of
##     17 so far) - drafting an inert card would be a dead pick; Joker is
##     excluded entirely, being rankless (spec 5) in an engine that can't
##     represent that yet
##   - a drafted card's rank is fixed to its catalogue rank_hint, not rolled -
##     spec 3.1 ties power to rank, but the draft doesn't offer rank choice
##   - refill-from-reserve is one swap-in per seat per round (spec 4.1 doesn't
##     specify granularity), not a full per-card negotiation - a big hand
##     isn't a wall of identical prompts

signal state_changed
signal game_over(loser: int)  # loser == -1 means everyone emptied at once (draw)

const HAND_SIZE := 6      # the refill target for a plain hand; _refill_target() may raise/lower it
const MIN_RANK := 6       # a 4-or-fewer-player game uses the classic 36-card deck (6..A)
const MIN_RANK_BIG := 2   # 5+ players: full 2..A ranks, and more than one deck if the pool needs it
const MAX_PLAYERS := 24   # the hard ceiling; the board and balance are only really tuned to ~6

const DRAFT_ROUNDS := 6         # spec 4.2: six picks over six rounds
const RESERVE_CAP := 6          # spec 4.1: up to 6 specials in reserve (a consequence of DRAFT_ROUNDS, not enforced separately)
const DRAFT_OFFER_SIZE := 3     # spec 4.2: one pick from three
const DRAFT_CATCHUP_SIZE := 4   # spec 4.3: whoever holds the most cards gets a 4th option

## Pool of ids SpecialEffects actually implements. Extend this the instant a
## new card's behaviour lands - see durak_game.gd's own doc comment.
const DRAFT_POOL: Array[StringName] = [
	&"overwhelm_bulwark", &"light", &"millstone", &"deadweight",
	&"sift", &"muzzle", &"barbed_cull", &"greedy_last",
]
## Round 1 offers boons only (spec 4.2 - nobody has a read on the table yet).
## Payload is the family the spec itself frames as "curses" throughout (4.4, 8.1).
const DRAFT_CURSE_FAMILY := SpecialCards.Family.PAYLOAD
## Spec 4.3's suggested catch-up subset (Bulwark/Light/Cull/Sift), translated to
## the merged dual-mode ids that actually carry those halves now.
const DRAFT_DEFENSIVE_IDS: Array[StringName] = [
	&"overwhelm_bulwark", &"light", &"barbed_cull", &"sift",
]

enum Phase { ATTACK, DEFEND, TAKING, REFILL_CHOICE, GAME_OVER }

## Special-card effect trigger points (spec 9). Event triggers fire through
## _fire() at the moment named; "while held" modifiers are queried instead, via
## _refill_target() / _attack_cap().
enum Trigger {
	ON_REFILL,           # a seat just drew its refill                     ctx = {seat, drawn}
	ON_PICKUP,           # a seat took the table into its hand             ctx = {seat, cards}
	ON_DEFENSE_SUCCESS,  # a bout resolved, defender beat it all           ctx = {defender, attacks, defenses}
	ON_DEFENSE_PLAYED,   # a defend card was placed                        ctx = {seat, card, target}
	ON_THROW_IN,         # an attack/throw-in card was placed              ctx = {seat, card}
	ON_ATTACK_END,       # a bout is being halted early by a card          ctx = {defender, beaten}
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

## Short human-readable notes on what a special just did (e.g. "P2's Cull
## discards a 6C"). Cleared at the top of every apply_action(); the view drains
## it after animating to show a toast. Empty in vanilla play.
var effect_log: Array[String] = []

# One-shot modifier slots a special writes into and the engine consumes once.
# Kept generic - this is plumbing any future on-play modifier can reuse, not
# behaviour itself (spec 9: data, not code); it just happens that Greedy/Last/
# Barbed/Muzzle are the only current writers.
var _refill_target_override: Dictionary = {}  # seat -> target, consumed by _refill_target()
var _refill_priority_seat: int = -1           # this seat refills first, this round only
var _refill_last_seat: int = -1               # this seat refills last, this round only
var _throw_in_locked: Dictionary = {}         # seat -> true: no attack/throw-in this bout
var _throw_in_locked_next: Dictionary = {}    # queued to activate next bout (Muzzle: "next round")

## Reserve (spec 4). Always allocated (one empty array per seat), even in
## vanilla play, so get_legal_actions()/etc. never need an `effects != null`
## guard just to index them - _generate_draft_offers() is the only thing that
## ever actually populates them, and it's a no-op while effects is null.
var reserves: Array[Array] = []       # reserves[seat] : Array[CardData], each is_special(), <= RESERVE_CAP
var draft_offers: Array[Array] = []   # draft_offers[seat] : Array[CardData] currently offered, [] = none pending
var draft_picks_used: Array[int] = [] # lifetime picks made per seat, capped at DRAFT_ROUNDS
var reserve_cards_created := 0        # running count - total_card_count()'s conserved total grows by this many

# Staged refill (spec 4.1's "talon or reserve" choice needs the engine to be
# able to pause mid-refill for a decision, unlike the single synchronous pass
# vanilla refill used to be). See _resolve_bout()/_advance_refill().
var _refill_pending: Array[int] = []  # seats still to refill this bout, in order
var _refill_choice_seat: int = -1     # seat currently offered a refill_choice, -1 = none
var _pending_attacker: int = -1       # staged attacker for the bout about to start, once refills finish

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

	# Draft picks (spec 4.2) are ambient - available whenever offered, on top of
	# whatever else this seat can currently do, not a phase of their own.
	for card in draft_offers[seat]:
		actions.append({type = "draft_pick", player = seat, card = card})

	if phase == Phase.REFILL_CHOICE:
		if seat == _refill_choice_seat:
			actions.append({type = "refill_choice", player = seat})  # draw from the talon
			for card in reserves[seat]:
				actions.append({type = "refill_choice", player = seat, card = card})
		return actions

	if seat == defender:
		if phase == Phase.DEFEND:
			for slot in table.size():
				if table[slot].defense == null:
					for card in hands[seat]:
						if card.beats(table[slot].attack, trump_suit) and _can_play_defense(card):
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
		if seat == attacker and _can_add_attack(seat) and not _throw_in_locked.has(seat):
			for card in hands[seat]:
				if _can_play_attack(card, true):
					actions.append({type = "attack", player = seat, card = card})
		return actions

	# bout in progress (defender is beating cards off or taking): throw in a card
	# of a rank already on the table, or pass
	if _can_add_attack(seat) and not _throw_in_locked.has(seat):
		var ranks_on_table := _table_ranks()
		for card in hands[seat]:
			if card.rank in ranks_on_table and _can_play_attack(card, false):
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


func total_card_count() -> int:  # invariant helper: always == pool_size() + reserve_cards_created
	var total := deck.size() + discard.size()
	for pair in table:
		total += 1
		if pair.defense != null:
			total += 1
	for hand in hands:
		total += hand.size()
	for reserve in reserves:
		total += reserve.size()
	return total


# ------------------------------------------------------------------ public apply

func apply_action(action: Dictionary) -> bool:
	if phase == Phase.GAME_OVER:
		return false
	if not _is_legal(action):
		return false
	effect_log.clear()
	match action.type:
		"attack": _apply_attack(action.player, action.card)
		"defend": _apply_defend(action.player, action.card, action.target)
		"deflect": _apply_deflect(action.player, action.card)
		"take": _apply_take(action.player)
		"pass": _apply_pass(action.player)
		"draft_pick": _apply_draft_pick(action.player, action.card)
		"refill_choice": _apply_refill_choice(action.player, action.get("card"))
		_: return false
	return true


# ------------------------------------------------------------------ setup

func _build_and_deal() -> void:
	for seat in num_players:
		hands.append([] as Array[CardData])
		is_out.append(false)
		reserves.append([] as Array[CardData])
		draft_offers.append([] as Array[CardData])
		draft_picks_used.append(0)

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

	trump_card = deck[0]
	trump_suit = trump_card.suit

	for _round in HAND_SIZE:
		for seat in num_players:
			hands[seat].append(deck.pop_back())

	attacker = _find_first_attacker()
	defender = _next_active(attacker)
	_set_attack_limit()
	_generate_draft_offers()  # spec 4.2: round 1's offers


## spec 3.5: 6 per player plus a 12-card buffer.
func pool_size() -> int:
	return 6 * num_players + 12


# --------------------------------------------------------------- reserve / draft

## Spec 4.2: at the start of a round (each bout, up to DRAFT_ROUNDS of them per
## seat), every active seat still drafting is shown fresh specials and picks
## one via a "draft_pick" action - see get_legal_actions()/_apply_draft_pick().
## No-op entirely while effects is null (vanilla).
func _generate_draft_offers() -> void:
	if effects == null:
		return
	var catchup_seat := _catchup_seat()
	for seat in num_players:
		if is_out[seat] or draft_picks_used[seat] >= DRAFT_ROUNDS or not draft_offers[seat].is_empty():
			continue
		var size := DRAFT_CATCHUP_SIZE if seat == catchup_seat else DRAFT_OFFER_SIZE
		draft_offers[seat] = _roll_offer(seat, size)


## Spec 4.3: the seat holding the most cards gets a 4th draft option - but
## only when someone's actually ahead of the pack (a fresh deal, or several
## seats tied at the top, isn't "the player currently holding the most cards",
## it's just the shape of a normal hand). Ties for the max break to the lowest
## seat number. -1 if nobody's still drafting, or nobody's actually struggling.
func _catchup_seat() -> int:
	var sizes := {}  # seat -> hand size, insertion order == seat order
	for seat in num_players:
		if is_out[seat] or draft_picks_used[seat] >= DRAFT_ROUNDS:
			continue
		sizes[seat] = hands[seat].size()
	if sizes.is_empty():
		return -1
	var max_size: int = sizes.values().max()
	if max_size == sizes.values().min():
		return -1
	for seat in sizes:
		if sizes[seat] == max_size:
			return seat
	return -1


func _roll_offer(seat: int, size: int) -> Array[CardData]:
	var pool := DRAFT_POOL.duplicate()
	if draft_picks_used[seat] == 0:  # spec 4.2: round 1 is boons only
		pool = pool.filter(func(id): return SpecialCards.DEFS[id].family != DRAFT_CURSE_FAMILY)
	var chosen: Array[StringName] = []
	for _i in mini(size, DRAFT_OFFER_SIZE):
		if pool.is_empty():
			break
		var id: StringName = pool[_rng.randi_range(0, pool.size() - 1)]
		pool.erase(id)
		chosen.append(id)
	if size > DRAFT_OFFER_SIZE:  # spec 4.3: the 4th, catch-up slot leans defensive
		var defensive: Array[StringName] = DRAFT_DEFENSIVE_IDS.filter(
			func(id): return id not in chosen)
		if defensive.is_empty():
			defensive = DRAFT_POOL.filter(func(id): return id not in chosen)
		if not defensive.is_empty():
			chosen.append(defensive[_rng.randi_range(0, defensive.size() - 1)])
	var offer: Array[CardData] = []
	for id in chosen:
		offer.append(_make_special_card(id))
	return offer


## A freshly manufactured special card for the draft. Not part of pool_size()'s
## count - the reserve is a genuinely separate supply (see the class doc
## comment). Rank is the catalogue's rank_hint (spec 3.1: rank is the price);
## suit is random and otherwise meaningless for a special.
func _make_special_card(id: StringName) -> CardData:
	var rank: int = clampi(SpecialCards.DEFS[id].rank_hint, MIN_RANK, 14)
	return CardData.new(_rng.randi_range(0, 3), rank, id)


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


## Sticky pass (house rule): once a seat declines to add a card this bout, it
## stays declined - re-asking it every time someone else adds a card that
## changes nothing for THEM would just be noise. Only reopened when a card
## just placed introduces a rank that wasn't on the table a moment ago (a
## genuinely new throw-in opportunity, not a second copy of one already
## offered and declined), and then only for seats who actually hold that rank -
## a new option someone else can use doesn't reopen anyone else's decision.
func _reopen_pass_for_new_ranks(ranks_before: Array) -> void:
	var new_ranks: Array = []
	for rank in _table_ranks():
		if rank not in ranks_before:
			new_ranks.append(rank)
	if new_ranks.is_empty():
		return
	for seat in passed.keys().duplicate():
		for card in hands[seat]:
			if card.rank in new_ranks:
				passed.erase(seat)
				break


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
	var ranks_before := _table_ranks()
	hands[seat].erase(card)
	table.append({attack = card, defense = null})
	_reopen_pass_for_new_ranks(ranks_before)
	if phase == Phase.ATTACK:
		phase = Phase.DEFEND
	state_changed.emit()
	_fire(Trigger.ON_THROW_IN, [card], {seat = seat, card = card})
	# A throw-in can be the last possible attack (hand emptied, or table full).
	if phase == Phase.TAKING:
		_maybe_resolve_taking()
	else:
		_maybe_resolve_defense()


func _apply_defend(seat: int, card: CardData, target: int) -> void:
	var ranks_before := _table_ranks()
	hands[seat].erase(card)
	table[target].defense = card
	_reopen_pass_for_new_ranks(ranks_before)
	state_changed.emit()
	_fire(Trigger.ON_DEFENSE_PLAYED, [card], {seat = seat, card = card, target = target})
	_maybe_resolve_defense()


func _apply_deflect(seat: int, card: CardData) -> void:
	var ranks_before := _table_ranks()
	hands[seat].erase(card)
	table.append({attack = card, defense = null})
	defender = _next_active(defender)  # old defender is now just an attacker
	_set_attack_limit()                # cap now follows the new defender's hand
	_reopen_pass_for_new_ranks(ranks_before)
	state_changed.emit()
	_fire(Trigger.ON_THROW_IN, [card], {seat = seat, card = card})


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


func _apply_draft_pick(seat: int, card: CardData) -> void:
	reserves[seat].append(card)
	draft_offers[seat] = []
	draft_picks_used[seat] += 1
	reserve_cards_created += 1
	effect_log.append("P%d drafts %s into their reserve" % [seat, SpecialCards.DEFS[card.special].name])
	state_changed.emit()


## `card` is null for "draw from the talon"; otherwise the specific reserve
## card to draw instead (spec 4.1). Either way this seat's refill is now
## settled for this round - _advance_refill() moves on to the next seat, or
## finishes the new bout if that was the last one.
func _apply_refill_choice(seat: int, card: CardData) -> void:
	if card == null:
		if not deck.is_empty():
			var talon_card: CardData = deck.pop_back()
			hands[seat].append(talon_card)
			_fire(Trigger.ON_REFILL, [talon_card], {seat = seat, drawn = [talon_card]})
	else:
		reserves[seat].erase(card)
		hands[seat].append(card)
		_fire(Trigger.ON_REFILL, [card], {seat = seat, drawn = [card]})
	_refill_choice_seat = -1
	_refill_pending.pop_front()
	state_changed.emit()
	_advance_refill()


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
	var bout_attacks: Array[CardData] = []
	var bout_defenses: Array[CardData] = []
	for pair in table:
		bout_attacks.append(pair.attack)
		if pair.defense != null:
			bout_defenses.append(pair.defense)
	var taken: Array[CardData] = bout_attacks + bout_defenses
	var destination: Array = hands[defender] if defender_took else discard
	destination.append_array(taken)
	table.clear()
	passed.clear()

	if defender_took:
		_fire(Trigger.ON_PICKUP, taken, {seat = defender, cards = taken})
	else:
		_fire(Trigger.ON_DEFENSE_SUCCESS, taken,
			{defender = defender, attacks = bout_attacks, defenses = bout_defenses})

	_pending_attacker = _next_active(defender) if defender_took else defender

	# Muzzle's "next round" lockout activates for the bout that's about to
	# start, not the one that just ended - this is the boundary between them.
	_throw_in_locked = _throw_in_locked_next
	_throw_in_locked_next = {}

	# Spec 4.2/4.3: offered before refill, while "holding the most cards" is
	# most meaningful (refill normalizes everyone back toward target).
	_generate_draft_offers()

	# Refill order: the bout that's about to start's attacker first, its
	# defender last (spec 2) - not the bout that just ended's. is_out won't
	# change again until _finish_new_bout()'s _update_out(), so it's safe to
	# compute the upcoming defender here for ordering purposes.
	var new_defender := _next_active(_pending_attacker)
	_refill_pending = []
	var seat := _pending_attacker
	for _step in num_players:
		if not is_out[seat]:
			_refill_pending.append(seat)
		seat = (seat + 1) % num_players
	_refill_pending.erase(new_defender)
	if not is_out[new_defender]:
		_refill_pending.append(new_defender)

	# Greedy/Last (spec 5, Economy): one-shot reorderings for this round only.
	# Both consumed here regardless of whether they actually apply (the seat
	# might already be out, or not in this round's order at all).
	if _refill_priority_seat != -1 and _refill_pending.has(_refill_priority_seat):
		_refill_pending.erase(_refill_priority_seat)
		_refill_pending.push_front(_refill_priority_seat)
	if _refill_last_seat != -1 and _refill_pending.has(_refill_last_seat):
		_refill_pending.erase(_refill_last_seat)
		_refill_pending.push_back(_refill_last_seat)
	_refill_priority_seat = -1
	_refill_last_seat = -1

	_advance_refill()


## Steps through _refill_pending one seat at a time. A seat with an empty
## reserve draws its whole quota from the talon in one go, same as vanilla. A
## seat with a non-empty reserve gets need-1 drawn automatically first, then
## pauses in Phase.REFILL_CHOICE for the one remaining slot (spec 4.1's "may
## come from the talon or your reserve", as a single per-round decision - not
## a full per-card negotiation, so a big hand isn't a wall of prompts).
## Spec 4.5: once the talon's dry, every refill stops outright, reserve
## included - no partial fallback to reserve once there's nothing left to
## choose between.
func _advance_refill() -> void:
	while not _refill_pending.is_empty():
		if deck.is_empty():
			_refill_pending.clear()
			break
		var seat: int = _refill_pending[0]
		# Computed once per seat, not per draw: _refill_target() consumes a
		# one-shot override (Barbed) the first time it's called, so calling it
		# again mid-loop would silently fall back to a different target partway
		# through this seat's own draw.
		var target := _refill_target(seat)
		var need := target - hands[seat].size()
		if need <= 0:
			_refill_pending.pop_front()
			continue

		var offer_choice := not reserves[seat].is_empty()
		var auto_draws := need - 1 if offer_choice else need
		var drawn: Array[CardData] = []
		while auto_draws > 0 and not deck.is_empty():
			var card: CardData = deck.pop_back()
			hands[seat].append(card)
			drawn.append(card)
			auto_draws -= 1
		# Fired after drawing, with what was actually drawn, so an on-draw
		# special (Forge/Tithe) sees itself as freshly arrived - firing before
		# the draw (the old behaviour) meant it could never see its own card.
		if not drawn.is_empty():
			_fire(Trigger.ON_REFILL, drawn, {seat = seat, drawn = drawn})

		if hands[seat].size() >= target or deck.is_empty():
			_refill_pending.pop_front()  # done, or the talon ran dry mid-draw - no choice left to offer
			continue
		_refill_choice_seat = seat
		phase = Phase.REFILL_CHOICE
		return
	_finish_new_bout()


func _finish_new_bout() -> void:
	_update_out()

	if _active_count() <= 1:
		phase = Phase.GAME_OVER
		loser = _last_active()
		if loser >= 0 and not finish_order.has(loser):
			finish_order.append(loser)  # the durak, last
		state_changed.emit()
		game_over.emit(loser)
		return

	var next_attacker := _pending_attacker
	if is_out[next_attacker]:
		next_attacker = _next_active(next_attacker)
	attacker = next_attacker
	defender = _next_active(attacker)
	_set_attack_limit()
	phase = Phase.ATTACK
	state_changed.emit()


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

## Fires `trigger` for exactly the specials in `cards` - the ones actually
## relevant to this event (the card just played, the pile just picked up, the
## cards just discarded, the cards just drawn). Deliberately NOT a blanket scan
## of every special anywhere in play: a Sift sitting quietly in someone's hand
## must not refire every time an unrelated pickup happens elsewhere.
func _fire(trigger: int, cards: Array[CardData], ctx: Dictionary) -> void:
	if effects == null:
		return
	for card in cards:
		if card.is_special():
			effects.handle(card.special, card, trigger, self, ctx)


## How many cards `seat` refills to this round. Default HAND_SIZE; Light lowers
## it, Millstone raises it (spec 5). A one-shot override (Barbed) wins over
## either and is consumed here.
func _refill_target(seat: int) -> int:
	if _refill_target_override.has(seat):
		var target: int = _refill_target_override[seat]
		_refill_target_override.erase(seat)
		return target
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


## Whether `card` may be played as an attack/throw-in right now. `is_lead` is
## true only when it would open a fresh bout (table empty). Default true;
## Deadweight (spec 5, Payload) restricts it to lead-only.
func _can_play_attack(card: CardData, is_lead: bool) -> bool:
	if effects == null:
		return true
	return effects.can_play_attack(card, is_lead, self)


## Whether `card` may be played to beat an attack right now. Default true;
## Deadweight (spec 5, Payload) forbids it outright.
func _can_play_defense(card: CardData) -> bool:
	if effects == null:
		return true
	return effects.can_play_defense(card, self)


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
