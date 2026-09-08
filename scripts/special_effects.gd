class_name SpecialEffects
extends RefCounted
## The one place special-card behaviour lives (spec 9: "data, not code" for the
## catalogue; this is the code the data points at). Assign an instance to
## DurakGame.effects to switch the roguelike layer on.
##
## Contract:
##   handle(id, trigger, game, ctx)  - event triggers. `trigger` is a
##       DurakGame.Trigger value; `ctx` shape is documented on the enum.
##       Only act if SpecialCards.DEFS[id].trigger matches this trigger.
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
	# SpecialCards.DEFS[id].trigger, as it's built.
	match id:
		_:
			pass


func refill_target(_seat: int, _game, base: int) -> int:
	return base


func attack_cap(_defender: int, _game, base: int) -> int:
	return base
