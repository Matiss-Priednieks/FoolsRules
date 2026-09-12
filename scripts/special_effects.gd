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
				_sift(game)
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
		_:
			pass


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


# --- Economy --------------------------------------------------------------
# Barbed/Cull, Greedy/Last, Sift. (Light is refill_target()-only, above.)

func _sift(game) -> void:
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
