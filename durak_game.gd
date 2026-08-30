class_name DurakGame
extends RefCounted
## Headless perevodnoy (podkidnoy) Durak. No rendering, no input, no AI.
##
## The view and the bots both drive it the same way:
##   for a in game.get_all_legal_actions(): ...          # what can happen now
##   game.apply_action(a)                                 # do one of them
##
## Contract: the `card` inside an action must be the exact CardData instance
## returned by get_legal_actions() (identity matters, hands hold references).
##
## The attacking side may lay down at most min(MAX_ATTACKS, defender's hand size
## at the start of the bout) cards, whether the defender is beating them off or
## taking. Overloading a taker past their hand size would be a deliberate
## variant, not the default.
##
## Known simplifications vs. full house rules:
##   - translation cannot bounce back onto the original attacker

signal state_changed
signal game_over(loser: int)  # loser == -1 means everyone emptied at once (draw)

const HAND_SIZE := 6
const MIN_RANK := 6      # 36-card deck: 6..A
const MAX_ATTACKS := 6   # cards the attacking side may lay down in one bout

enum Phase { ATTACK, DEFEND, TAKING, GAME_OVER }

var num_players: int
var hands: Array[Array] = []      # hands[p] : Array[CardData]
var deck: Array[CardData] = []    # talon; draw from the back. deck[0] is the trump card.
var discard: Array[CardData] = []
var trump_card: CardData          # kept for display after it is drawn
var trump_suit: int

# Current bout
var table: Array[Dictionary] = []  # [{attack: CardData, defense: CardData|null}, ...]
var attacker: int                  # primary attacker (opens the bout, refills first)
var defender: int
var phase: int = Phase.ATTACK
var attack_limit: int               # max cards on the table this bout; set when the bout/defender is set
var passed: Dictionary = {}         # attacker index -> true, since the last table change

var is_out: Array[bool] = []        # finished the game (empty hand, empty talon)
var finish_order: Array[int] = []   # seats in the order they went out; the durak is last
var loser: int = -1
var seed_used: int

var _rng := RandomNumberGenerator.new()


func _init(players: int = 4, game_seed: int = 0) -> void:
	num_players = players
	seed_used = game_seed if game_seed != 0 else \
		int(Time.get_unix_time_from_system() * 1000.0) & 0x7fffffff
	_rng.seed = seed_used
	_build_and_deal()


# ------------------------------------------------------------------ public query

func get_legal_actions(player: int) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	if phase == Phase.GAME_OVER or is_out[player]:
		return actions

	if player == defender:
		if phase == Phase.DEFEND:
			for i in table.size():
				if table[i].defense == null:
					for c in hands[player]:
						if c.beats(table[i].attack, trump_suit):
							actions.append({type = "defend", player = player, card = c, target = i})
			if _can_translate():
				var r: int = table[0].attack.rank
				for c in hands[player]:
					if c.rank == r:
						actions.append({type = "translate", player = player, card = c})
			actions.append({type = "take", player = player})
		return actions

	# attacking side: everyone who is not the defender
	if phase == Phase.ATTACK or phase == Phase.TAKING:
		var can_add := _can_add_attack(player)
		if table.is_empty():
			if player == attacker and can_add:
				for c in hands[player]:
					actions.append({type = "attack", player = player, card = c})
			return actions
		if can_add:
			var ranks := _table_ranks()
			for c in hands[player]:
				if c.rank in ranks:
					actions.append({type = "attack", player = player, card = c})
		if not passed.has(player) and not hands[player].is_empty():
			actions.append({type = "pass", player = player})
	return actions


func get_all_legal_actions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in num_players:
		out.append_array(get_legal_actions(p))
	return out


func players_to_act() -> Array[int]:
	var out: Array[int] = []
	for p in num_players:
		if not get_legal_actions(p).is_empty():
			out.append(p)
	return out


func talon_count() -> int:
	return deck.size()


func is_finished() -> bool:
	return phase == Phase.GAME_OVER


func total_card_count() -> int:  # invariant helper: always 36
	var n := deck.size() + discard.size() + table.size()
	for pair in table:
		if pair.defense != null:
			n += 1
	for h in hands:
		n += h.size()
	return n


# ------------------------------------------------------------------ public apply

func apply_action(action: Dictionary) -> bool:
	if phase == Phase.GAME_OVER:
		return false
	if not _is_legal(action):
		return false
	match action.type:
		"attack": _apply_attack(action.player, action.card)
		"defend": _apply_defend(action.player, action.card, action.target)
		"translate": _apply_translate(action.player, action.card)
		"take": _apply_take(action.player)
		"pass": _apply_pass(action.player)
		_: return false
	return true


# ------------------------------------------------------------------ setup

func _build_and_deal() -> void:
	for p in num_players:
		hands.append([] as Array[CardData])
		is_out.append(false)

	for suit in 4:
		for rank in range(MIN_RANK, 15):
			deck.append(CardData.new(suit, rank))
	_shuffle(deck)

	trump_card = deck[0]
	trump_suit = trump_card.suit

	for _i in HAND_SIZE:
		for p in num_players:
			hands[p].append(deck.pop_back())

	attacker = _find_first_attacker()
	defender = _next_active(attacker)
	_set_attack_limit()


func _set_attack_limit() -> void:
	attack_limit = mini(MAX_ATTACKS, hands[defender].size())


func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func _find_first_attacker() -> int:
	var best_player := 0
	var best_rank := 99
	for p in num_players:
		for c in hands[p]:
			if c.suit == trump_suit and c.rank < best_rank:
				best_rank = c.rank
				best_player = p
	return best_player


# ------------------------------------------------------------------ rules helpers

func _next_active(from: int) -> int:
	var p := (from + 1) % num_players
	while is_out[p] and p != from:
		p = (p + 1) % num_players
	return p


func _active_count() -> int:
	var n := 0
	for o in is_out:
		if not o:
			n += 1
	return n


func _unbeaten_count() -> int:
	var n := 0
	for pair in table:
		if pair.defense == null:
			n += 1
	return n


func _table_ranks() -> Array:
	var s := {}
	for pair in table:
		s[pair.attack.rank] = true
		if pair.defense != null:
			s[pair.defense.rank] = true
	return s.keys()


func _can_add_attack(player: int) -> bool:
	if hands[player].is_empty():
		return false
	return table.size() < attack_limit


func _can_translate() -> bool:
	if phase != Phase.DEFEND or table.is_empty():
		return false
	var r: int = table[0].attack.rank
	for pair in table:
		if pair.defense != null:  # something already beaten -> no translation
			return false
		if pair.attack.rank != r:
			return false
	var next_def := _next_active(defender)
	if next_def == defender or next_def == attacker:
		return false
	return hands[next_def].size() >= table.size() + 1


# ------------------------------------------------------------------ action apply

func _apply_attack(player: int, card: CardData) -> void:
	hands[player].erase(card)
	table.append({attack = card, defense = null})
	passed.clear()
	if phase == Phase.ATTACK:
		phase = Phase.DEFEND
	state_changed.emit()
	# A throw-in can be the last possible attack (hand emptied, or table full).
	if phase == Phase.TAKING:
		_maybe_resolve_taking()
	else:
		_maybe_resolve_defense()


func _apply_defend(player: int, card: CardData, target: int) -> void:
	hands[player].erase(card)
	table[target].defense = card
	passed.clear()
	state_changed.emit()
	_maybe_resolve_defense()


func _apply_translate(player: int, card: CardData) -> void:
	hands[player].erase(card)
	table.append({attack = card, defense = null})
	defender = _next_active(defender)  # old defender is now just an attacker
	_set_attack_limit()               # cap now follows the new defender's hand
	passed.clear()
	state_changed.emit()


func _apply_take(player: int) -> void:
	phase = Phase.TAKING
	passed.clear()
	state_changed.emit()
	_maybe_resolve_taking()


func _apply_pass(player: int) -> void:
	passed[player] = true
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
	for p in num_players:
		if p == defender or is_out[p] or hands[p].is_empty():
			continue
		if not passed.has(p) and _can_add_attack(p):
			return true
	return false


func _resolve_bout(defender_took: bool) -> void:
	for pair in table:
		var sink: Array = hands[defender] if defender_took else discard
		sink.append(pair.attack)
		if pair.defense != null:
			sink.append(pair.defense)
	table.clear()
	passed.clear()

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
	var order: Array[int] = []
	var p := attacker
	for _i in num_players:
		if not is_out[p]:
			order.append(p)
		p = (p + 1) % num_players
	order.erase(defender)          # defender always refills last
	if not is_out[defender]:
		order.append(defender)
	for pl in order:
		while hands[pl].size() < HAND_SIZE and not deck.is_empty():
			hands[pl].append(deck.pop_back())


func _update_out() -> void:
	if not deck.is_empty():
		return
	for p in num_players:
		if not is_out[p] and hands[p].is_empty():
			is_out[p] = true
			finish_order.append(p)


func _last_active() -> int:
	for p in num_players:
		if not is_out[p]:
			return p
	return -1


# ------------------------------------------------------------------ validation

func _is_legal(action: Dictionary) -> bool:
	if not action.has("type") or not action.has("player"):
		return false
	for a in get_legal_actions(action.player):
		if a.type != action.type:
			continue
		if a.get("card") != action.get("card"):
			continue
		if a.get("target", -1) != action.get("target", -1):
			continue
		return true
	return false
