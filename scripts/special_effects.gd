class_name SpecialEffects
extends RefCounted
## The one place special-card behaviour lives (spec 9: "data, not code" for the
## catalogue; this is the code the data points at). Assign an instance to
## DurakGame.effects to switch the roguelike layer on.
##
## Contract:
##   handle(id, card, trigger, game, ctx)  - event triggers. `trigger` is a
##       DurakGame.Trigger value; `ctx` shape is documented on the enum. `card`
##       is the specific CardData instance that fired this - needed to tell a
##       dual-mode card's two roles apart (spec 3.8) when ctx doesn't already
##       imply the role (ON_DEFENSE_SUCCESS names both `attacks` and `defenses`
##       since both roles fire on the same event; ON_THROW_IN/ON_DEFENSE_PLAYED
##       each only ever mean one role, so `trigger` alone tells them apart).
##   refill_target(seat, game, base) - "while held" query: return the number of
##       cards `seat` should refill to (default `base`, = DurakGame.HAND_SIZE).
##   attack_cap(defender, game, base) - "while held" query: return the max cards
##       the attacking side may lay down this bout (default `base`, = the
##       defender's hand size).
##   can_play_attack(card, is_lead, game) / can_play_defense(card, game) -
##       legality queries: may `card` be played as an attack/throw-in (lead or
##       not) or as a defence right now? Default true; Deadweight is the only
##       current user.
##
## Effects that use randomness MUST go through `game._rng`, never global random -
## multiplayer replays the same action stream on every peer and would desync
## otherwise.

## Set true to trace every fired trigger to the console while wiring effects up.
const TRACE := false


func handle(id: StringName, card: CardData, trigger: int, game, ctx: Dictionary) -> void:
	if TRACE:
		print("[fx] %s <- trigger %d" % [id, trigger])
	match id:
		&"sift":
			if trigger == DurakGame.Trigger.ON_PICKUP:
				_sift(game, card)
		&"muzzle":
			if trigger == DurakGame.Trigger.ON_PICKUP:
				_muzzle(game, ctx.seat)
		&"barbed_cull":
			if trigger != DurakGame.Trigger.ON_DEFENSE_SUCCESS:
				return
			if card in ctx.attacks:
				_barbed(game, ctx.defender)
			elif card in ctx.defenses:
				_cull(game, ctx.defender)
		&"greedy_last":
			if trigger == DurakGame.Trigger.ON_THROW_IN:
				_greedy(game, ctx.seat)
			elif trigger == DurakGame.Trigger.ON_DEFENSE_PLAYED:
				_last(game)
		&"holdout":
			if trigger == DurakGame.Trigger.ON_THROW_IN:
				_holdout(game, ctx.seat)
		&"tithe":
			if trigger == DurakGame.Trigger.ON_REFILL:
				_tithe(game)
		&"singleout_ricochet":
			if trigger == DurakGame.Trigger.ON_THROW_IN:
				_request_singleout(game, ctx.seat)
		&"scramble_turnabout":
			if trigger == DurakGame.Trigger.ON_DEFENSE_SUCCESS and card in ctx.attacks:
				_scramble(game)
			elif trigger == DurakGame.Trigger.ON_DEFENSE_PLAYED:
				_turnabout(game)
		&"palm":
			if trigger == DurakGame.Trigger.ON_THROW_IN:
				_request_palm(game, ctx.seat)
		&"stack":
			if trigger == DurakGame.Trigger.ON_THROW_IN:
				_request_stack(game, ctx.seat)
		&"forge":
			if trigger == DurakGame.Trigger.ON_REFILL:
				_request_forge(game, ctx.seat)
		&"mirror":
			if trigger == DurakGame.Trigger.ON_THROW_IN:
				_mirror_attack(game, ctx.seat)
			elif trigger == DurakGame.Trigger.ON_DEFENSE_PLAYED:
				_mirror_defense(game, ctx.seat)
		_:
			pass  # compel_sidestep, riveted_rebound: can_take()/can_deflect_any_rank() query hooks only, no event


func refill_target(seat: int, game, base: int) -> int:
	# Light and Millstone are both while_held: check whoever's refilling for
	# either sitting anywhere in their hand right now. If a seat somehow has
	# both, Millstone (a curse someone else dumped on them) wins over Light
	# (a boon they picked themselves) - a judgment call, not a spec ruling.
	var target := base
	for c in game.hands[seat]:
		if c.special == &"light":
			target = 5
	for c in game.hands[seat]:
		if c.special == &"millstone":
			target = 7
	return target


func attack_cap(_defender: int, game, base: int) -> int:
	# Overwhelm / Bulwark (spec 5, Table-shape) - the first card implemented,
	# chosen to prove the dual-mode pattern (spec 3.8) end to end: one id, two
	# roles, told apart by which side of the table pairing it's sitting on.
	# Called both at bout start (table is already cleared then, so this is a
	# no-op) and live on every _can_add_attack() check thereafter, so playing
	# either half takes effect the instant the card lands.
	var result := base
	for pair in game.table:
		if pair.attack.special == &"overwhelm_bulwark":
			result += 2  # Overwhelm: this attack may exceed the base cap by 2
	for pair in game.table:
		if pair.defense != null and pair.defense.special == &"overwhelm_bulwark":
			result = mini(result, 4)  # Bulwark: caps at 4, wins any tie with Overwhelm
	return result


## Deadweight (spec 5, Payload).
func can_play_attack(card: CardData, is_lead: bool, _game) -> bool:
	if card.special == &"deadweight":
		return is_lead
	return true


## Deadweight (spec 5, Payload).
func can_play_defense(card: CardData, _game) -> bool:
	if card.special == &"deadweight":
		return false
	return true


## Compel (spec 5, Table-shape): may the defender concede right now? False
## only while a Compel attack sits unbeaten on the table AND a complete
## defense is still legally possible - a Compel attack the defender genuinely
## can't fully answer doesn't trap them (matches the catalogue's own wording).
func can_take(game) -> bool:
	var has_compel := false
	for pair in game.table:
		if pair.defense == null and pair.attack.special == &"compel_sidestep":
			has_compel = true
			break
	if not has_compel:
		return true
	return not game._can_full_defense(game.defender)


## Sidestep (spec 5, Table-shape defense half): this specific card may deflect
## without matching the lead rank.
func can_deflect_any_rank(card: CardData, _game) -> bool:
	return card.special == &"compel_sidestep"


## Ricochet (spec 5, Deflect defense half): this specific card, played as a
## deflect, lands one seat further than usual.
func deflect_skips_one(card: CardData, _game) -> bool:
	return card.special == &"singleout_ricochet"


# --- Economy --------------------------------------------------------------
# Barbed/Cull, Greedy/Last, Sift. (Light is refill_target()-only, above.)

## One-shot per physical copy: being picked up puts the card into the taker's
## hand (not the discard), so without this it could be thrown back in and
## picked up again indefinitely - each repeat pulling 3 more discard cards
## into the talon and fighting spec 3.5's fixed clock every time. Firing once
## and going ordinary (special cleared) caps a single copy's total economy
## impact, matching the catalogue's "when picked up" as a one-time event, not
## a standing "every time" curse like Muzzle's.
func _sift(game, card: CardData) -> void:
	var moved := mini(3, game.discard.size())
	for _i in moved:
		var idx: int = game._rng.randi_range(0, game.discard.size() - 1)
		game.deck.append(game.discard.pop_at(idx))
	if moved > 0:
		game._shuffle(game.deck)
		game.effect_log.append(
			"Sift shuffles %d card%s from the discard back into the talon" % [
				moved, "" if moved == 1 else "s"])
	else:
		# Always log, even the no-op: the discard pile is genuinely empty this
		# early in a hand (nothing has ever been successfully defended yet), and
		# a silent no-op reads as "the card didn't work" rather than "nothing to
		# shuffle yet" - what actually happened.
		game.effect_log.append("Sift finds nothing in the discard to shuffle")
	card.special = &""  # spent - an ordinary card from here on, however this pickup went


func _barbed(game, defender: int) -> void:
	game._refill_target_override[defender] = 7
	game.effect_log.append("Barbed refills P%d to 7 this round" % defender)


func _cull(game, seat: int) -> void:
	var hand: Array = game.hands[seat]
	if hand.is_empty():
		return
	var trump: int = game.trump_suit
	var worst: CardData = hand[0]
	for c in hand:
		if _card_price(c, trump) < _card_price(worst, trump):
			worst = c
	hand.erase(worst)
	game.discard.append(worst)
	game.effect_log.append("Cull discards P%d's %s" % [seat, str(worst)])


func _greedy(game, seat: int) -> void:
	game._refill_priority_seat = seat
	game.effect_log.append("Greedy gives P%d refill priority this round" % seat)


func _last(game) -> void:
	game._refill_last_seat = game.attacker
	game.effect_log.append("Last pushes P%d to refill last this round" % game.attacker)


# --- Payload ---------------------------------------------------------------
# Muzzle. (Deadweight is can_play_attack()/can_play_defense()-only, above;
# Millstone is refill_target()-only.)

func _muzzle(game, seat: int) -> void:
	game._throw_in_locked_next[seat] = true
	game.effect_log.append("Muzzle locks P%d out of throwing in next round" % seat)


func _card_price(card: CardData, trump: int) -> int:
	return card.rank + (100 if card.suit == trump else 0)


# --- Sleight ----------------------------------------------------------------
# Holdout, Tithe. (Stack/Palm/Forge/Mirror need a choice the action shape
# doesn't carry yet - see durak_game.gd's class doc comment.)

func _holdout(game, seat: int) -> void:
	if game.discard.is_empty():
		game.effect_log.append("Holdout finds nothing in the discard to take")
		return
	var idx: int = game._rng.randi_range(0, game.discard.size() - 1)
	var card: CardData = game.discard.pop_at(idx)
	game.hands[seat].append(card)
	game.effect_log.append("Holdout takes a %s from the discard into P%d's hand" % [str(card), seat])


## Opposite of Cull's "worst card" (spec 5): every active seat with a hand
## gives up its single highest-value card (rank, trump-boosted same as
## _card_price elsewhere). Includes the seat that just drew Tithe - "every
## player" has no exception, so a trump-suited Tithe can tithe itself the
## instant it lands if it's genuinely that seat's priciest card right now.
func _tithe(game) -> void:
	var trump: int = game.trump_suit
	var count := 0
	for seat in game.num_players:
		if game.is_out[seat] or game.hands[seat].is_empty():
			continue
		var hand: Array = game.hands[seat]
		var best: CardData = hand[0]
		for c in hand:
			if _card_price(c, trump) > _card_price(best, trump):
				best = c
		hand.erase(best)
		game.discard.append(best)
		count += 1
	if count > 0:
		game.effect_log.append("Tithe collects each player's highest card")
	else:
		game.effect_log.append("Tithe finds no hands to collect from")


# --- Mid-effect player choices (Palm/Singleout/Stack/Forge) ----------------
# DurakGame only hosts the pause/resume plumbing (_request_special_choice()/
# _apply_special_choice()); what a pending choice actually offers and does is
# entirely this file's call, via the two functions below.

## Legal "special_choice" actions for whoever `game._special_choice` names as
## the deciding seat - called from DurakGame.get_legal_actions() every time,
## same as any other legal-action query.
func special_choice_actions(choice: Dictionary, game, seat: int) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	match choice.kind:
		"palm", "singleout":
			for other in game.num_players:
				if other == seat or game.is_out[other]:
					continue
				if choice.kind == "palm" and game.hands[other].is_empty():
					continue
				# Singleout may never hand defense to the primary attacker -
				# the engine assumes defender != attacker everywhere else.
				if choice.kind == "singleout" and other == game.attacker:
					continue
				actions.append({type = "special_choice", player = seat, target = other})
		"stack":
			for card in choice.pool:
				actions.append({type = "special_choice", player = seat, card = card})
		"forge_target":
			for card in game.hands[seat]:
				actions.append({type = "special_choice", player = seat, card = card})
		"forge_source":
			for card in game.hands[seat]:
				if card == choice.target:
					continue
				actions.append({type = "special_choice", player = seat, card = card, target = 0})  # rank
				if card.suit != game.trump_suit:
					actions.append({type = "special_choice", player = seat, card = card, target = 1})  # suit
	return actions


## Applies one submitted "special_choice" action. Returns true once the whole
## choice is resolved (DurakGame then resumes whatever was paused); false to
## stay paused for another step of the same multi-step choice, having mutated
## `choice` in place to carry state into that next step.
func apply_special_choice(choice: Dictionary, game, seat: int, action: Dictionary) -> bool:
	match choice.kind:
		"palm":
			_finish_palm(game, seat, action.target)
			return true
		"singleout":
			_finish_singleout(game, seat, action.target)
			return true
		"stack":
			choice.order.append(action.card)
			choice.pool.erase(action.card)
			if not choice.pool.is_empty():
				return false
			_finish_stack(game, seat, choice.order)
			return true
		"forge_target":
			choice.kind = "forge_source"
			choice.target = action.card
			return false
		"forge_source":
			var mode := "suit" if action.get("target", 0) == 1 else "rank"
			_finish_forge(game, seat, choice.target, action.card, mode)
			return true
	return true


## Palm (spec 5, Sleight): trade one random card with a chosen opponent. Only
## requested if some other seat actually has a card to trade - otherwise a
## no-op log, never a choice with zero legal targets (that would deadlock the
## table: SPECIAL_CHOICE blocks every other seat until this one answers).
func _request_palm(game, seat: int) -> void:
	var has_target := false
	for other in game.num_players:
		if other != seat and not game.is_out[other] and not game.hands[other].is_empty():
			has_target = true
			break
	if not has_target:
		game.effect_log.append("Palm finds no one to trade with")
		return
	game._request_special_choice(seat, "palm", {}, "attack_resolve")


func _finish_palm(game, seat: int, target: int) -> void:
	var mine: Array = game.hands[seat]
	var theirs: Array = game.hands[target]
	if mine.is_empty() or theirs.is_empty():
		return
	var mine_card: CardData = mine[game._rng.randi_range(0, mine.size() - 1)]
	var their_card: CardData = theirs[game._rng.randi_range(0, theirs.size() - 1)]
	mine.erase(mine_card)
	theirs.erase(their_card)
	mine.append(their_card)
	theirs.append(mine_card)
	game.effect_log.append("Palm trades a card between P%d and P%d" % [seat, target])


## Singleout (spec 5, Deflect): the thrower picks who defends. Simplified to
## the whole bout (see durak_game.gd's class doc comment) - always has at
## least one valid target while the game is still running (the game ends the
## instant only one seat is left active), so no empty-choice guard is needed
## the way Palm's is.
func _request_singleout(game, seat: int) -> void:
	game._request_special_choice(seat, "singleout", {}, "attack_resolve")


func _finish_singleout(game, _seat: int, target: int) -> void:
	game.defender = target
	game._set_attack_limit()
	game.effect_log.append("Singleout makes P%d the defender this bout" % target)


## Stack (spec 5, Sleight): look at the talon's top 5 and rearrange them - a
## sequence of single-card picks (build the new order one slot at a time,
## same UX shape as the draft) rather than one big reorder action. Only
## requested while the talon actually has cards - otherwise there is nothing
## to look at and the choice would have zero legal actions.
func _request_stack(game, seat: int) -> void:
	if game.deck.is_empty():
		game.effect_log.append("Stack finds an empty talon to look at")
		return
	var n: int = mini(5, game.deck.size())
	var pool: Array = game.deck.slice(game.deck.size() - n, game.deck.size())
	game._request_special_choice(seat, "stack", {pool = pool, order = []}, "attack_resolve")


func _finish_stack(game, seat: int, order: Array) -> void:
	var n: int = order.size()
	for i in n:
		game.deck[game.deck.size() - n + i] = order[n - 1 - i]  # order[0] = drawn first = nearest the back
	game.effect_log.append("Stack rearranges the talon's top %d cards for P%d" % [n, seat])


## Forge (spec 5, Sleight): copy another hand card's rank or suit onto a
## chosen card, until the round ends (durak_game.gd's _resolve_bout() reverts
## it). Two-step choice (target, then source+mode) - only requested with a
## second card actually available to copy from; ON_REFILL guarantees the
## drawing seat's hand is never empty, but it could be down to just the one
## card just drawn.
func _request_forge(game, seat: int) -> void:
	if game.hands[seat].size() < 2:
		game.effect_log.append("Forge finds nothing else in P%d's hand to copy" % seat)
		return
	game._request_special_choice(seat, "forge_target", {}, "refill_continue")


func _finish_forge(game, seat: int, target: CardData, source: CardData, mode: String) -> void:
	game._forge_overrides.append({card = target, rank = target.rank, suit = target.suit})
	if mode == "rank":
		target.rank = source.rank
		game.effect_log.append("Forge copies %s's rank onto P%d's %s" % [str(source), seat, str(target)])
	else:
		target.suit = source.suit
		game.effect_log.append("Forge copies %s's suit onto P%d's %s" % [str(source), seat, str(target)])


## Scramble (spec 5, Deflect attack half): when beaten and discarded, seating
## order scrambles for the rest of the match. Excluded below 4 players per
## the catalogue note - too small a table for "seating order" to mean much.
func _scramble(game) -> void:
	if game.num_players < 4:
		game.effect_log.append("Scramble needs at least 4 players to shuffle seating")
		return
	game._shuffle(game._turn_order)
	game.effect_log.append("Scramble shuffles the seating order for the rest of the match")


## Turnabout (spec 5, Deflect defense half): table direction reverses,
## permanently.
func _turnabout(game) -> void:
	game._turn_direction *= -1
	game.effect_log.append("Turnabout reverses the direction of play")


## Mirror (spec 5, Sleight): peeks write to private_log (seat-scoped, not the
## shared effect_log toast) - the whole point is only the peeking seat sees it.
func _mirror_attack(game, seat: int) -> void:
	var defender_hand: Array = game.hands[game.defender]
	if defender_hand.is_empty():
		return
	var pool: Array = defender_hand.duplicate()
	game._shuffle(pool)
	var peek: Array = pool.slice(0, mini(3, pool.size()))
	var shown: Array = peek.map(func(c): return str(c))
	game.private_log.append({seat = seat,
		text = "Mirror reveals %d of P%d's cards: %s" % [peek.size(), game.defender, ", ".join(shown)]})


func _mirror_defense(game, seat: int) -> void:
	var lines: Array[String] = []
	for other in game.num_players:
		if other == seat or game.is_out[other] or game.hands[other].is_empty():
			continue
		var pool: Array = game.hands[other]
		var card: CardData = pool[game._rng.randi_range(0, pool.size() - 1)]
		lines.append("P%d: %s" % [other, str(card)])
	if not lines.is_empty():
		game.private_log.append({seat = seat,
			text = "Mirror peeks at one card from each opponent - %s" % ", ".join(lines)})
