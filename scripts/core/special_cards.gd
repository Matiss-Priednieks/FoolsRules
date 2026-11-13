class_name SpecialCards
extends RefCounted
## Catalogue of the special cards: names, families, triggers and rules text.

## The trigger point an effect hangs off, matched against DurakGame.Trigger.
## `while_held` effects have no event - they answer the query hooks
## (DurakGame._refill_target / _attack_cap) whenever the engine asks.
enum Family { ECONOMY, TABLE_SHAPE, PAYLOAD, DEFLECT, JOKER, SLEIGHT, HAZARD }

## Card frame / nameplate paint per family (card_fx.gdshader): muted military
## / industrial colours to fit the Soviet post-apocalyptic art direction.
const FAMILY_COLORS := {
	Family.ECONOMY: Color(0.42, 0.45, 0.22), # olive drab
	Family.TABLE_SHAPE: Color(0.34, 0.42, 0.50), # slate
	Family.PAYLOAD: Color(0.17, 0.15, 0.14), # soot (curses)
	Family.DEFLECT: Color(0.26, 0.46, 0.40), # oxidised teal-green
	Family.JOKER: Color(0.56, 0.58, 0.58), # worn steel
	Family.SLEIGHT: Color(0.62, 0.18, 0.14), # faded Soviet red
	Family.HAZARD: Color(0.80, 0.62, 0.16), # warning ochre (frame drawn as black/ochre stripes)
}
## Families whose frame is drawn as black/ochre warning stripes instead of a
## solid paint - keeps Hazards unmistakable rather than adding a 7th solid
## colour that would sit too close to the others.
const FAMILY_STRIPES := [Family.HAZARD]
## Player-facing category name + one-line explanation per family (Card Archive
## headings; reusable anywhere a family is shown). Plain words on purpose - a
## category should explain itself from its name.
const FAMILY_INFO := {
	Family.ECONOMY: ["Refills", "Change how many cards get drawn, and who draws first."],
	Family.TABLE_SHAPE: ["Attack Rules", "Bend an attack's rules: how big it can get, whether you can give up, how you can pass."],
	Family.DEFLECT: ["Redirect", "Change who has to defend: send it back, skip a seat, reshuffle the seating."],
	Family.SLEIGHT: ["Tricks", "Cheat a little: peek at hands, rig the deck, swap or steal cards."],
	Family.PAYLOAD: ["Curses", "Bad cards hidden in the deck. Get rid of them fast."],
	Family.JOKER: ["The Joker", "Unbeatable in defence. One per game."],
	Family.HAZARD: ["Hazards", "Fire, fallout and frost: dangers that burn, poison or freeze the cards themselves."],
}
## Frame outline overrides; default is the family colour darkened.
const FAMILY_OUTLINES := {
	Family.PAYLOAD: Color(0.62, 0.30, 0.12), # rust edge on the soot curses
	Family.HAZARD: Color(0.10, 0.09, 0.07), # the stripes' black
}

## id -> { name, family, rank_hint, note, trigger } for a single-mode card, or
## { name, family, rank_hint, dual = true, attack = {trigger, note}, defense =
## {trigger, note} } for a dual-mode one (spec 3.8: one card, two effects - one
## per role it's played in. Only on-play triggers are eligible for dual mode;
## a card that fires on refill/pickup/while-held has no play moment to branch
## on and stays single-mode).
##   trigger : &"while_held" | one of DurakGame.Trigger's names, lower-cased
##   rank_hint : the rank the effect is priced around (spec 3.1) - low = potent
const DEFS := {
	# --- The Joker: the one rankless card, the power ceiling (spec 5) ----
	&"joker": {
		name = "Joker", family = Family.JOKER, trigger = &"on_defense_played",
		rank_hint = 0, note = "unbeatable in defence; once it's down, nobody can throw in for the rest of the attack. Cannot go out on it",
	},

	# --- Economy (spec 5) --------------------------------------------------
	&"barbed_cull": {
		name = "Barbed / Cull", family = Family.ECONOMY, dual = true, rank_hint = 7,
		attack = {trigger = &"on_defense_success",
			note = "when successfully defended, the defender refills to 7 this round"},
		defense = {trigger = &"on_defense_success",
			note = "after a successful defense, discard one card from your hand face-up"},
	},
	&"light": {
		name = "Light", family = Family.ECONOMY, trigger = &"while_held",
		rank_hint = 8, note = "holder refills to 5 instead of 6",
	},
	&"greedy_last": {
		name = "Greedy / Last", family = Family.ECONOMY, dual = true, rank_hint = 9,
		attack = {trigger = &"on_throw_in", note = "you take refill priority this round"},
		defense = {trigger = &"on_defense_played",
			note = "the attacking player refills last this round"},
	},
	&"sift": {
		name = "Sift", family = Family.ECONOMY, trigger = &"on_pickup",
		rank_hint = 7, note = "the first time it's picked up, shuffle three cards from the discard back into the talon - then it's just a plain card",
	},

	# --- Table-shape (spec 5) -------------------------------------------
	&"overwhelm_bulwark": {
		name = "Overwhelm / Bulwark", family = Family.TABLE_SHAPE, dual = true, rank_hint = 6,
		attack = {trigger = &"on_throw_in",
			note = "this attack may exceed the defender's hand size by 2"},
		defense = {trigger = &"on_defense_played",
			note = "attacks against you cap at 4 cards this round"},
	},
	&"compel_sidestep": {
		name = "Compel / Sidestep", family = Family.TABLE_SHAPE, dual = true, rank_hint = 7,
		attack = {trigger = &"on_throw_in",
			note = "the defender may not concede if a complete defense is legally possible"},
		defense = {trigger = &"on_defense_played",
			note = "pass without needing to match rank (does not bypass the throw-in lockout)"},
	},
	# Cut: Anchor (attack cannot be conceded, beat everything or pick up
	# double). Superseded by Compel - it punished the defender who couldn't
	# defend as hard as the one choosing not to, and under uncapped attacks
	# "pick up double" could be match-ending on one card.

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
	&"riveted_rebound": {
		name = "Riveted / Rebound", family = Family.DEFLECT, dual = true, rank_hint = 9,
		attack = {trigger = &"on_throw_in", note = "this attack cannot be passed"},
		defense = {trigger = &"on_defense_played",
			note = "pass the attack backwards, to the player who attacked you (once per attack)"},
	},
	&"singleout_ricochet": {
		name = "Singleout / Ricochet", family = Family.DEFLECT, dual = true, rank_hint = 9,
		attack = {trigger = &"on_throw_in",
			note = "choose which player defends this attack, ignoring seating"},
		defense = {trigger = &"on_defense_played",
			note = "your pass skips the next player, landing two seats over"},
	},
	&"scramble_turnabout": {
		name = "Scramble / Turnabout", family = Family.DEFLECT, dual = true, rank_hint = 6,
		attack = {trigger = &"on_defense_success",
			note = "when this card is beaten and discarded, seating order is randomly scrambled for the rest of the match (exclude below 4 players)"},
		defense = {trigger = &"on_defense_played", note = "table direction reverses, permanently"},
	},
	# Cut: Boomerang (defended cards discarded, attacking cards returned to
	# their owners). Killed after four rewrites - its denial half was a no-op
	# during the talon phase, its rescue half needed an exception to the
	# early-end-attack ruling, and every fix created a new edge case. Do not
	# revive.

	# --- Sleight: peeking, palming, stacking the deck (spec 5) ----------
	&"stack": {
		name = "Stack", family = Family.SLEIGHT, trigger = &"on_throw_in",
		rank_hint = 6, note = "look at the talon's top 5 cards and rearrange them",
	},
	&"palm": {
		name = "Palm", family = Family.SLEIGHT, trigger = &"on_throw_in",
		rank_hint = 8, note = "trade one random card with a chosen opponent",
	},
	&"holdout": {
		name = "Holdout", family = Family.SLEIGHT, trigger = &"on_throw_in",
		rank_hint = 7, note = "take one card from the discard pile into your hand",
	},
	&"mirror": {
		name = "Mirror", family = Family.SLEIGHT, dual = true, rank_hint = 9,
		attack = {trigger = &"on_throw_in", note = "peek at 3 random cards from the defender's hand"},
		defense = {trigger = &"on_defense_played",
			note = "peek at 1 random card from every other player"},
	},
	&"forge": {
		name = "Forge", family = Family.SLEIGHT, trigger = &"on_refill",
		rank_hint = 7, note = "choose a card in your hand; it takes the suit or rank of another card in your hand until end of round - cannot copy trump",
	},
	&"samogon": {
		name = "Spilt Samogon", family = Family.SLEIGHT, trigger = &"on_defense_success",
		rank_hint = 8, note = "when it's beaten as an attack, it sticks to the table instead of being discarded - two attacks later it comes back as an extra attack, against whoever's defending then",
	},
	&"requisition": {
		name = "Requisition", family = Family.SLEIGHT, trigger = &"on_defense_success",
		rank_hint = 9, note = "when this beats a special card, take that special into your hand instead of discarding it",
	},
	&"samizdat": {
		name = "Samizdat", family = Family.SLEIGHT, trigger = &"on_throw_in",
		rank_hint = 8, note = "repeats the effect of the last special thrown in this game, as if you'd thrown it",
	},
	&"solidarity": {
		name = "Solidarity", family = Family.SLEIGHT, trigger = &"on_throw_in",
		rank_hint = 7, note = "every other special already attacking on the table triggers its effect again, for you",
	},

	# --- Refills (cross-family additions) -----------------------------
	&"black_market": {
		name = "Black Market", family = Family.ECONOMY, trigger = &"on_throw_in",
		rank_hint = 8, note = "this round you refill from the top of the discard pile instead of the talon",
	},
	&"ration_card": {
		name = "Ration Card", family = Family.ECONOMY, trigger = &"on_throw_in",
		rank_hint = 6, note = "everyone refills to 5 this round - and you refill first",
	},

	# --- Redirect / Attack Rules (cross-family additions) ---------------
	&"denunciation": {
		name = "Denunciation", family = Family.DEFLECT, trigger = &"on_throw_in",
		rank_hint = 8, note = "name a player: they defend the next attack. Everyone learns whether they hold a Curse",
	},
	&"propaganda": {
		name = "Propaganda", family = Family.TABLE_SHAPE, trigger = &"on_throw_in",
		rank_hint = 7, note = "when you attack with it, it counts as a trump until the round ends",
	},
	&"iron_curtain": {
		name = "Iron Curtain", family = Family.TABLE_SHAPE, trigger = &"on_throw_in",
		rank_hint = 9, note = "until this attack ends, only the lead attacker may throw in",
	},

	# --- Hazards: dangers that act on the cards themselves ---------------
	&"flame_hazard": {
		name = "Flame Hazard", family = Family.HAZARD, trigger = &"on_defense_success",
		rank_hint = 8, note = "when it beats a card, or is beaten, both cards burn - out of the game for good. Even a Curse",
	},
	&"fallout": {
		name = "Fallout", family = Family.HAZARD, trigger = &"on_pickup",
		rank_hint = 7, note = "whoever picks this up gets 1-2 of the picked-up cards irradiated for two rounds: irradiated cards can't defend",
	},
	&"frostbite": {
		name = "Frostbite", family = Family.HAZARD, trigger = &"on_throw_in",
		rank_hint = 6, note = "the defender's best card freezes until the end of next round: it can't defend or be thrown in",
	},
	&"blackout": {
		name = "Blackout", family = Family.HAZARD, trigger = &"while_held",
		rank_hint = 9, note = "while this is attacking on the table, cards of any rank may be thrown in",
	},
	&"purge": {
		name = "Purge", family = Family.HAZARD, trigger = &"on_refill",
		rank_hint = 7, note = "when you draw it, every Curse in your hand burns, and your frozen or irradiated cards recover",
	},

	&"tithe": {
		name = "Tithe", family = Family.SLEIGHT, trigger = &"on_refill",
		rank_hint = 6, note = "every player discards their highest-value card",
	},
}


static func exists(id: StringName) -> bool:
	return DEFS.has(id)


static func is_dual(id: StringName) -> bool:
	return DEFS.has(id) and DEFS[id].get("dual", false)


## `role`: &"attack" or &"defense" - which half to look up on a dual-mode card
## (ignored, along with the default, for a single-mode one).
static func trigger_of(id: StringName, role: StringName = &"attack") -> StringName:
	if not DEFS.has(id):
		return &""
	var def: Dictionary = DEFS[id]
	if def.get("dual", false):
		return def[role].trigger if def.has(role) else &""
	return def.get("trigger", &"")


## Full effect text for a hover tooltip (spec 9). A single-mode card's `note`
## as-is; a dual-mode card's two notes labelled by role, since the card reads
## differently depending which side of the table it ends up on.
static func tooltip_text(id: StringName) -> String:
	if not DEFS.has(id):
		return ""
	var def: Dictionary = DEFS[id]
	if not def.get("dual", false):
		return "%s: %s" % [def.name, def.note]
	return "%s\nAttack: %s\nDefense: %s" % [def.name, def.attack.note, def.defense.note]
