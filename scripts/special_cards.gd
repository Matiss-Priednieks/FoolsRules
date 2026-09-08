class_name SpecialCards
extends RefCounted
## Catalogue of roguelike special cards (spec 5). Data only - no behaviour lives
## here. SpecialEffects reads `trigger` to know when to act; the draft / reserve
## systems read `family` and `rank_hint` to build offers.
##
## A special is applied to an ordinary CardData by setting its `special` field to
## one of these ids. Rank/suit/beats() are untouched (spec 3.1): a "boomerang 7"
## is a 7 in every rules respect.

## The trigger point an effect hangs off, matched against DurakGame.Trigger.
## `while_held` effects have no event - they answer the query hooks
## (DurakGame._refill_target / _attack_cap) whenever the engine asks.
enum Family { ECONOMY, TABLE_SHAPE, BOOMERANG, PAYLOAD, DEFLECT, JOKER }

## id -> { name, family, trigger, rank_hint, note }
##   trigger : &"while_held" | one of DurakGame.Trigger's names, lower-cased
##   rank_hint : the rank the effect is priced around (spec 3.1) - low = potent
const DEFS := {
	# --- Economy (spec 5) --------------------------------------------------
	&"barbed": {
		name = "Barbed", family = Family.ECONOMY, trigger = &"on_defense_success",
		rank_hint = 10, note = "on a successful defence the defender refills to 7 this round",
	},
	&"light": {
		name = "Light", family = Family.ECONOMY, trigger = &"while_held",
		rank_hint = 8, note = "holder refills to 5 instead of 6",
	},
	&"greedy": {
		name = "Greedy", family = Family.ECONOMY, trigger = &"while_held",
		rank_hint = 9, note = "holder takes refill priority this round",
	},
	&"last": {
		name = "Last", family = Family.ECONOMY, trigger = &"while_held",
		rank_hint = 9, note = "target refills last this round",
	},
	&"cull": {
		name = "Cull", family = Family.ECONOMY, trigger = &"on_defense_success",
		rank_hint = 7, note = "after a successful defence, discard one card face-up",
	},
	&"sift": {
		name = "Sift", family = Family.ECONOMY, trigger = &"on_pickup",
		rank_hint = 7, note = "when picked up, shuffle three discards back into the talon",
	},

	# --- Table-shape (spec 5) -------------------------------------------
	&"bulwark": {
		name = "Bulwark", family = Family.TABLE_SHAPE, trigger = &"while_held",
		rank_hint = 8, note = "defender-side: attacks against the holder cap at 4 this round",
	},
	&"overwhelm": {
		name = "Overwhelm", family = Family.TABLE_SHAPE, trigger = &"while_held",
		rank_hint = 6, note = "attacker-side: this attack may exceed the defender's hand by 2",
	},
	&"anchor": {
		name = "Anchor", family = Family.TABLE_SHAPE, trigger = &"on_attack_end",
		rank_hint = 8, note = "this attack cannot be conceded - beat it all or pick up double",
	},
	&"boomerang": {
		name = "Boomerang", family = Family.BOOMERANG, trigger = &"on_defense_played",
		rank_hint = 9, note = "defends normally, then ends the attack: defenders discard, attacks return to owners, boomerang discards",
	},

	# --- Payload: works in someone else's hand (spec 5, face-up) --------
	&"deadweight": {
		name = "Deadweight", family = Family.PAYLOAD, trigger = &"while_held",
		rank_hint = 6, note = "can only be played as an attack lead - never thrown in, never a defence",
	},
	&"millstone": {
		name = "Millstone", family = Family.PAYLOAD, trigger = &"while_held",
		rank_hint = 6, note = "holder refills to 7",
	},
	&"muzzle": {
		name = "Muzzle", family = Family.PAYLOAD, trigger = &"on_pickup",
		rank_hint = 7, note = "whoever picks this up cannot throw in cards next round",
	},

	# --- Pass / deflect: the only family that picks a target (spec 5) ---
	&"sidestep": {
		name = "Sidestep", family = Family.DEFLECT, trigger = &"on_defense_played",
		rank_hint = 9, note = "deflect once without matching rank (does not bypass the throw-in lockout)",
	},
	&"ricochet": {
		name = "Ricochet", family = Family.DEFLECT, trigger = &"on_defense_played",
		rank_hint = 9, note = "your deflect skips the next player, landing two seats over",
	},
	&"riveted": {
		name = "Riveted", family = Family.DEFLECT, trigger = &"while_held",
		rank_hint = 9, note = "this attack cannot be deflected - beat it or take it",
	},

	# --- Joker: the one rankless card, the power ceiling (spec 5) -------
	&"joker": {
		name = "Joker", family = Family.JOKER, trigger = &"on_defense_played",
		rank_hint = 0, note = "unbeatable in defence, ends the attack; cannot go out on it",
	},
}


static func exists(id: StringName) -> bool:
	return DEFS.has(id)


static func trigger_of(id: StringName) -> StringName:
	return DEFS[id].trigger if DEFS.has(id) else &""
