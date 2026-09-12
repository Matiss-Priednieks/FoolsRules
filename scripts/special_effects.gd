class_name SpecialEffects
extends RefCounted
## The one place special-card behaviour lives (spec 9: "data, not code" for the
## catalogue; this is the code the data points at). Assign an instance to
## DurakGame.effects to switch the roguelike layer on.
##
## Contract:
##   handle(id, trigger, game, ctx)  - event triggers. `trigger` is a
##       DurakGame.Trigger value; `ctx` shape is documented on the enum.
##       Only act if SpecialCards.trigger_of(id, role) matches this trigger -
##       a dual-mode card (spec 3.8) needs the right role, attack or defense,
##       which ctx/table tells you (was this id the attack or defense card in
##       the bout that just fired the trigger).
##   refill_target(seat, game, base) - "while held" query: return the number of
##       cards `seat` should refill to (default `base`, = DurakGame.HAND_SIZE).
##   attack_cap(defender, game, base) - "while held" query: return the max cards
##       the attacking side may lay down this bout (default `base`, = the
##       defender's hand size).
##
## Effects that use randomness MUST go through `game._rng`, never global random -
## multiplayer replays the same action stream on every peer and would desync
## otherwise.

## Set true to trace every fired trigger to the console while wiring effects up.
const TRACE := false


func handle(id: StringName, trigger: int, _game, _ctx: Dictionary) -> void:
	if TRACE:
		print("[fx] %s <- trigger %d" % [id, trigger])
	# No effects implemented yet. Each card gets a branch here, gated on
	# SpecialCards.trigger_of(id, role), as it's built.
	match id:
		_:
			pass


func refill_target(_seat: int, _game, base: int) -> int:
	return base


## Overwhelm / Bulwark (spec 5, Table-shape) is the first card implemented -
## chosen to prove the dual-mode pattern (spec 3.8) end to end: one id, two
## roles, told apart by which side of the table pairing it's sitting on.
## Called both at bout start (table is already cleared then, so this is a
## no-op) and live on every _can_add_attack() check thereafter, so playing
## either half takes effect the instant the card lands.
func attack_cap(_defender: int, game, base: int) -> int:
	var result := base
	for pair in game.table:
		if pair.attack.special == &"overwhelm_bulwark":
			result += 2  # Overwhelm: this attack may exceed the base cap by 2
	for pair in game.table:
		if pair.defense != null and pair.defense.special == &"overwhelm_bulwark":
			result = mini(result, 4)  # Bulwark: attacks against you cap at 4 - wins any tie with Overwhelm
	return result
