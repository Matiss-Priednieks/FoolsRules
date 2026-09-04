extends Node2D
## The playable board. Seat `human_seat` is the user (Slay-the-Spire style drag);
## the other seats are driven by Bot. Rendering is identity-based: every card owns
## one persistent Sprite2D kept in `_card_views` (keyed by its CardData). On each
## rules change the views tween to their new positions, so pickups, refills and
## finished bouts stay followable. Hidden zones (opponent hands, the talon body,
## the discard pile) are drawn as pools of face-down "back" sprites.

const CARD_SCENE := preload("res://scenes/card.tscn")
const SUIT_GLYPHS := ["♣", "♦", "♥", "♠"]
const BOARD_CENTER := Vector2(960, 540)

@export var human_seat := 0 ## -1 = watch mode (every seat is a bot)

@export_group("Pacing (seconds)")
@export_range(0.0, 3.0, 0.05) var bot_delay := 0.7 ## pause before each bot move; the board stays live during it
@export_range(0.0, 1.5, 0.01) var move_duration := 0.34 ## generic settle tween
@export_range(0.0, 1.5, 0.01) var play_anim := 0.30 ## played card sliding onto the table
@export_range(0.0, 1.5, 0.01) var play_beat := 0.34 ## hold after a card is played
@export_range(0.0, 1.5, 0.01) var clear_anim := 0.40 ## cards leaving the table (to discard / into a hand)
@export_range(0.0, 1.5, 0.01) var clear_beat := 0.34 ## hold after the table clears
@export_range(0.0, 1.5, 0.01) var refill_anim := 0.26 ## a card flying from the talon into a hand
@export_range(0.0, 1.5, 0.01) var refill_beat := 0.14 ## hold after each seat refills
@export_range(0.0, 1.0, 0.01) var deal_fly := 0.24 ## opening deal: one card's flight from the talon
@export_range(0.0, 0.5, 0.01) var deal_gap := 0.045 ## opening deal: gap between consecutive cards
@export_range(0.0, 0.8, 0.01) var deal_player_beat := 0.10 ## opening deal: pause between one player's hand and the next

@export_group("Card feel")
@export_range(0.0, 120.0, 1.0) var hover_raise := 46.0 ## px a hovered hand card lifts
@export_range(1.0, 1.6, 0.01) var hover_scale := 1.12 ## size multiplier while hovered
@export_range(0.0, 25.0, 0.5) var hover_tilt := 8.0 ## deg a hovered card leans toward the cursor (Balatro-ish)
@export_range(0.05, 1.0, 0.01) var hand_follow := 0.30 ## how fast hand cards ease to their slot
@export_range(0.05, 1.0, 0.01) var drag_follow := 0.40 ## how fast a dragged card chases the cursor

@export_group("Hand fan")
@export_range(250.0, 5000.0, 10.0) var hand_fan_radius := 900.0 ## arc radius of the human hand; larger = flatter, smaller = deeper curve
@export_range(24.0, 160.0, 1.0) var hand_card_spacing := 82.0 ## gap between adjacent hand cards along the arc

@export_group("Card sizes (px tall)")
@export_range(40.0, 320.0, 1.0) var hand_card_height := 200.0
@export_range(40.0, 320.0, 1.0) var table_card_height := 140.0
@export_range(40.0, 320.0, 1.0) var talon_card_height := 140.0
@export_range(40.0, 320.0, 1.0) var opponent_card_height := 118.0
@export_range(40.0, 320.0, 1.0) var discard_card_height := 130.0

@export_group("Audio")
@export var sfx_enabled := true
@export_range(-40.0, 6.0, 0.5) var sfx_volume_db := -6.0
@export_range(0.0, 0.20, 0.005) var deal_stagger := 0.05 ## gap between clicks when several cards move at once

@export_group("CRT")
@export var crt_enabled := true:
	set(value):
		crt_enabled = value
		var crt := get_node_or_null("CRT")
		if crt:
			crt.visible = value

@export_group("Pixelate")
@export var pixelate_enabled := true:
	set(value):
		pixelate_enabled = value
		var px := get_node_or_null("Pixelate")
		if px:
			px.visible = value

@export_group("Positions")
@export var talon_pos := Vector2(250, 560)
@export var discard_pos := Vector2(1690, 560)
@export var table_drop_rect := Rect2(500, 350, 920, 380) ## where a dragged card counts as "on the table"
@export var translate_strip_rect := Rect2(660, 232, 600, 96) ## the "pass the attack on" drop strip

var game: DurakGame

# --- persistent scene nodes (see game.tscn for the actual layout) ---------------
@onready var _slot_layer: Node2D = $SlotLayer # empty-pile outline markers, drawn behind the cards
@onready var _talon_marker: Line2D = $SlotLayer/TalonMarker
@onready var _discard_marker: Line2D = $SlotLayer/DiscardMarker
@onready var _card_layer: Node2D = $CardLayer # every card / back sprite lives here
@onready var _ui_layer: CanvasLayer = $UI
@onready var _ui_root: Control = $UI/Root # every Control below hangs off this one themed node
@onready var _status_label: Label = $UI/Root/StatusLabel # top line: trump / phase / pile counts
@onready var _talon_label: Label = $UI/Root/TalonLabel
@onready var _discard_label: Label = $UI/Root/DiscardLabel
@onready var _seat_labels: Array[Label] = [
	$UI/Root/SeatLabel0, $UI/Root/SeatLabel1, $UI/Root/SeatLabel2, $UI/Root/SeatLabel3]
@onready var _hand_sort_button: Button = $UI/Root/HandSortButton
@onready var _confirm_button: Button = $UI/Root/ConfirmButton
@onready var _take_button: Button = $UI/Root/TakeButton
@onready var _pass_button: Button = $UI/Root/PassButton
@onready var _translate_strip: ColorRect = $UI/Root/TranslateStrip # "drop here to pass the attack on"
@onready var _end_screen: ColorRect = $UI/Root/EndScreen
@onready var _end_title: Label = $UI/Root/EndScreen/EndTitle
@onready var _end_standings: Label = $UI/Root/EndScreen/EndStandings
@onready var _again_button: Button = $UI/Root/EndScreen/AgainButton
@onready var _menu_button: Button = $UI/Root/EndScreen/MenuButton

# --- view bookkeeping --------------------------------------------------------
var _card_views: Dictionary = {} # CardData   -> Sprite2D (one per face-up card)
var _opponent_backs: Dictionary = {} # seat (int) -> Array[Sprite2D]
var _talon_stack: Array[Sprite2D] = []
var _discard_stack: Array[Sprite2D] = []

# --- frame state ------------------------------------------------------------
var _game_id := 0 # bumped per game; a stale coroutine bails on mismatch
var _turn_epoch := 0 # bumped when the human acts; the bot loop bails on mismatch
var _busy := false # an _apply_and_animate() is mid-flight
var _waiting_for_human := false # the human has at least one legal move right now
var _move_pending := false # human has laid ≥1 card this turn, not yet released to the bots
var _awaiting_ack := false # multiplayer client: our own action is in flight to the host
var _hand_slots: Array = [] # [{view, card, home_pos, home_angle, home_scale, playable}]
var _open_attack_views: Array = [] # [{view, table_index}] for not-yet-beaten attacks
var _drag := {} # {view, card, home_pos, grab_offset} while dragging
var _hovered_view: Node = null
var _headless := false
var _hand_sort := "rank" # "rank" | "suit" - purely local display order, never touches game.hands

# --- audio ----------------------------------------------------------------
const AUDIO_VOICES := 14
var _deal_streams: Array[AudioStream] = [] # deal_1..9: one card moving
var _fan_streams: Array[AudioStream] = [] # card_fan_1..3: a pile picked up / swept to discard
var _voices: Array[AudioStreamPlayer] = []
var _voice_next := 0


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if _headless:
		bot_delay = 0.0 # keep any headless run (smoke test or a --lan-* test) fast
	else:
		_init_audio()

	if _headless and not NetSession.active:
		human_seat = -1 # plain headless run: the self-play smoke test
	elif NetSession.active:
		human_seat = NetSession.local_seat # launched from a multiplayer lobby or LAN test
		print("[net] multiplayer game: seat=%d authority=%s peer=%s unique_id=%d" % [
			human_seat, _is_authority(), multiplayer.multiplayer_peer,
			multiplayer.get_unique_id()])
		if _headless:
			# Neither a headless host nor a headless client has a UI to drag
			# cards with, so both need a stand-in for OUR seat specifically -
			# the host's own seat isn't a bot seat either. Goes through the
			# same _perform()/RPC path a real drag-and-drop would. Deferred:
			# _new_game() (called at the end of _ready()) hasn't built `game`
			# yet at this point.
			_run_client_autoplay.call_deferred()

	var crt := get_node_or_null("CRT")
	if crt:
		crt.visible = crt_enabled and not _headless
	var px := get_node_or_null("Pixelate")
	if px:
		px.visible = pixelate_enabled and not _headless

	_set_slot_marker_points(_talon_marker, talon_card_height)
	_set_slot_marker_points(_discard_marker, discard_card_height)
	_place_slots()
	# translate_strip_rect is a tunable export, not baked into the scene
	_translate_strip.position = translate_strip_rect.position
	_translate_strip.size = translate_strip_rect.size

	_hand_sort_button.pressed.connect(_on_hand_sort_pressed)
	_confirm_button.pressed.connect(_on_confirm)
	_take_button.pressed.connect(_on_take)
	_pass_button.pressed.connect(_on_pass)
	_again_button.pressed.connect(_restart)
	_menu_button.pressed.connect(_to_menu)

	RenderingServer.set_default_clear_color(Color(0.05, 0.22, 0.12))
	_new_game()


# a card-footprint outline that marks a pile spot even when it is empty
func _set_slot_marker_points(marker: Line2D, card_height: float) -> void:
	var w := card_height * (500.0 / 726.0)
	var half := Vector2(w, card_height) * 0.5
	marker.points = PackedVector2Array([
		- half, Vector2(half.x, -half.y), half, Vector2(-half.x, half.y),
	])


func _place_slots() -> void:
	_talon_marker.position = talon_pos
	_discard_marker.position = discard_pos
	_talon_label.position = talon_pos \
		+ Vector2(-_talon_label.size.x * 0.5, talon_card_height * 0.5 + 8.0)
	_discard_label.position = discard_pos \
		+ Vector2(-_discard_label.size.x * 0.5, discard_card_height * 0.5 + 8.0)


# ---------------------------------------------------------------- game lifecycle

func _new_game() -> void:
	_game_id += 1
	_turn_epoch += 1
	_busy = false
	_move_pending = false
	_awaiting_ack = false
	# In multiplayer every peer must deal identically without transmitting the
	# deal itself, so they all build the same DurakGame from the same seed.
	var game_seed := NetSession.seed if NetSession.active else 0
	game = DurakGame.new(4, game_seed)
	game.game_over.connect(_on_game_over)
	_deal_out() # animate the deal, then settle + hand off to the bots


## Counter-clockwise seat order (left -> top -> right -> home in screen terms),
## so the human's own hand fills last.
func _deal_order() -> Array[int]:
	var order: Array[int] = []
	for relative in [1, 2, 3, 0]:
		order.append((_near_seat() + relative) % game.num_players)
	return order


## The engine has already dealt; this just animates the result before anyone
## moves - each hand flown out of the talon a card at a time, seat by seat,
## then _resync() settles the exact layout and the bots take over.
func _deal_out() -> void:
	var run_id := _game_id
	_busy = true

	if _headless:
		_busy = false
		_resync()
		if _is_authority():
			_run_bot_turns()
		return

	for label in _seat_labels:
		label.text = ""
	_sync_back_stack(_talon_stack, game.talon_count() - 1, talon_pos, talon_card_height, -1)
	_place_slots()

	for seat in _deal_order():
		var hand: Array = game.hands[seat]
		for i in hand.size():
			if run_id != _game_id:
				return
			if seat == _near_seat():
				var card: CardData = hand[i]
				var view := _create_view(card) # spawns at the talon
				_card_views[card] = view
				view.z_index = 10 + i
				_animate_to(view, _hand_slot_pos(i, hand.size()),
					_hand_slot_angle(i, hand.size()),
					_fit_scale(view, hand_card_height), deal_fly, 0.0)
			else:
				_opponent_backs.get_or_add(seat, [])
				var back := _new_back(talon_pos, 4)
				_opponent_backs[seat].append(back)
				# turns to face its seat mid-flight
				_animate_to(back, _opponent_slot_pos(seat, i, hand.size()),
					_seat_layout(seat).facing,
					_fit_scale(back, opponent_card_height), deal_fly, 0.0)
			_play_deal()
			await _wait(deal_gap)
		await _wait(deal_player_beat)

	if run_id != _game_id:
		return
	_busy = false
	_resync() # settle the exact layout, flip the trump out, unlock input
	if _is_authority():
		_run_bot_turns()


func _to_menu() -> void:
	if NetSession.active:
		SteamLobby.leave() # no-op for a LAN test (never touched SteamLobby)
		multiplayer.multiplayer_peer = null # tears down a LAN test's ENet peer too
	NetSession.active = false
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _restart() -> void:
	if NetSession.active:
		_to_menu() # multiplayer has no redeal button yet
		return
	_end_screen.visible = false
	for view in _card_views.values():
		if is_instance_valid(view):
			view.queue_free()
	_card_views.clear()
	for backs in _opponent_backs.values():
		for back in backs:
			if is_instance_valid(back):
				back.queue_free()
	_opponent_backs.clear()
	for back in _talon_stack + _discard_stack:
		if is_instance_valid(back):
			back.queue_free()
	_talon_stack.clear()
	_discard_stack.clear()
	_hand_slots.clear()
	_open_attack_views.clear()
	_drag = {}
	_hovered_view = null
	if game != null and game.game_over.is_connected(_on_game_over):
		game.game_over.disconnect(_on_game_over)
	_new_game()


func _on_game_over(loser: int) -> void:
	print("game over - durak is %s" % ("draw" if loser < 0 else "P%d" % loser))
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	_show_end_screen(loser)


func _show_end_screen(loser: int) -> void:
	var shown_for := _game_id
	await get_tree().create_timer(0.55).timeout
	if shown_for != _game_id:
		return
	if loser < 0:
		_end_title.text = "Draw"
	elif human_seat == loser:
		_end_title.text = "You are the durak"
	elif human_seat >= 0:
		var place := game.finish_order.find(human_seat)
		_end_title.text = "You got out %s" % ["1st", "2nd", "3rd", "4th"][maxi(place, 0)]
	else:
		_end_title.text = "P%d is the durak" % loser
	var rows: Array[String] = []
	for i in game.finish_order.size():
		var seat: int = game.finish_order[i]
		var who := "You" if seat == human_seat else "P%d" % seat
		var outcome := "durak" if i == game.finish_order.size() - 1 else "safe"
		rows.append("%d.  %s  —  %s" % [i + 1, who, outcome])
	_end_standings.text = "\n".join(rows)
	_end_screen.visible = true


# ---------------------------------------------------------------- bot turn loop

## Keeps letting bots act, one at a time, until only a human (local or, in
## multiplayer, someone on the other end of the wire) can move, or the game
## ends. `bot_delay` paces the gap *between* consecutive bot moves only - the
## first bot reply after a human acts is immediate, and control returns to the
## human as soon as the last bot has moved (no trailing wait). A human move
## bumps `_turn_epoch`, making this loop bail so a fresh one starts after it.
## Host/singleplayer only - see _is_authority().
func _run_bot_turns() -> void:
	var run_id := _game_id
	var epoch := _turn_epoch
	while not game.is_finished():
		if run_id != _game_id or epoch != _turn_epoch:
			return
		if _busy: # a human move slipped in and is animating; wait it out
			await _wait(0.05)
			continue
		var excluded := _bot_excluded_seats()
		var action: Dictionary = Bot.pick(game, excluded)
		if action.is_empty():
			return # only a human seat can move now
		await _perform(action)
		if run_id != _game_id or epoch != _turn_epoch or game.is_finished():
			return
		if bot_delay > 0.0 and not Bot.pick(game, excluded).is_empty():
			await _wait(bot_delay) # only pause if another bot move is coming


# ---------------------------------------------------------------- multiplayer sync
##
## Singleplayer and the multiplayer host both decide moves locally (their own
## drag/drop, or Bot.pick for a bot seat) and are "the authority": _perform()
## just runs _apply_and_animate() as always, then tells any other peers what
## happened. A multiplayer client never touches its own DurakGame directly -
## it asks the host over RPC and waits for that same broadcast to come back,
## so every peer only ever advances its board by replaying an action the host
## has already validated. Every peer's DurakGame started from the same seed
## (NetSession.seed), so replaying the same actions in the same order keeps
## them bit-identical without ever transmitting a snapshot.

func _is_authority() -> bool:
	if not NetSession.active:
		return true
	if SteamLobby.in_lobby:
		return SteamLobby.is_host # Steam lobby ownership, independent of the RPC peer's state
	return multiplayer.is_server() # LAN test / any other transport: ENet's server is peer id 1


## Seats Bot.pick must never move for: this peer's own seat (if it's playing)
## plus, in multiplayer, every seat some other human controls - the host waits
## for their action over the network instead of auto-playing it.
func _bot_excluded_seats() -> Array:
	var excluded: Array = []
	if human_seat >= 0:
		excluded.append(human_seat)
	if NetSession.active:
		for seat in NetSession.seat_is_bot.size():
			if not NetSession.seat_is_bot[seat] and seat not in excluded:
				excluded.append(seat)
	return excluded


## The single choke point every locally-decided action flows through, whether
## it came from this peer's own drag/drop or from Bot.pick.
func _perform(action: Dictionary) -> void:
	if _is_authority():
		await _apply_and_animate(action)
		if NetSession.active:
			net_apply_action.rpc(_action_to_wire(action))
	else:
		_awaiting_ack = true
		net_request_action.rpc_id(1, _action_to_wire(action))
		_await_ack(action)


## Defensive-only: a well-behaved host always answers. If it doesn't (a lost
## packet, a desync), unstick the client's input rather than freeze it forever.
func _await_ack(action: Dictionary) -> void:
	await _wait(6.0)
	if _awaiting_ack:
		push_warning("[net] host never answered a %s" % action.type)
		_awaiting_ack = false
		_resync()


## A client -> host request to apply `wire`. Runs on the host only.
## Godot's RPC dispatch does NOT wait for one call's internal awaits to finish
## before invoking the next incoming call - a burst of broadcasts (e.g. a bout
## resolving through several bot moves) can call this again while the first is
## still mid-_apply_and_animate(). Queue + drain one at a time, or two applies
## interleave and the mirrors desync.
var _incoming_requests: Array = [] # host: [{wire, seat}] from clients, arrival order
var _draining_requests := false
var _incoming_broadcasts: Array = [] # client: [wire] from the host, arrival order
var _draining_broadcasts := false


## A client -> host request to apply `wire`. Runs on the host only.
@rpc("any_peer", "call_remote", "reliable")
func net_request_action(wire: Dictionary) -> void:
	if not _is_authority():
		return
	var seat := _seat_for_peer(multiplayer.get_remote_sender_id())
	if seat < 0:
		return
	_incoming_requests.append({wire = wire, seat = seat})
	if not _draining_requests:
		_drain_incoming_requests()


func _drain_incoming_requests() -> void:
	_draining_requests = true
	while not _incoming_requests.is_empty():
		var entry: Dictionary = _incoming_requests.pop_front()
		var action := _resolve_wire_action(entry.wire, entry.seat)
		if not action.is_empty(): # else stale/illegal - the sender's watchdog will retry
			_turn_epoch += 1 # a network move pre-empts the bot loop same as a local one
			await _apply_and_animate(action)
			net_apply_action.rpc(_action_to_wire(action))
	_draining_requests = false
	_run_bot_turns()


## The host -> everyone broadcast of an action it just applied. Runs on clients.
@rpc("authority", "call_remote", "reliable")
func net_apply_action(wire: Dictionary) -> void:
	_incoming_broadcasts.append(wire)
	if not _draining_broadcasts:
		_drain_incoming_broadcasts()


func _drain_incoming_broadcasts() -> void:
	_draining_broadcasts = true
	while not _incoming_broadcasts.is_empty():
		var wire: Dictionary = _incoming_broadcasts.pop_front()
		var seat: int = wire.get("player", -1)
		var action := _resolve_wire_action(wire, seat)
		if seat == human_seat:
			_awaiting_ack = false
		if not action.is_empty():
			await _apply_and_animate(action)
	_draining_broadcasts = false


## Host-only. Two transports feed this: a LAN test fills NetSession.seat_peer_id
## with real Godot peer ids directly; Steam only gives us a steam_id per seat,
## so SteamLobby resolves the RPC sender's Godot peer id back to that.
func _seat_for_peer(peer_id: int) -> int:
	var lan_seat := NetSession.seat_peer_id.find(peer_id)
	if lan_seat != -1:
		return lan_seat
	var sid := SteamLobby.steam_id_for_peer(peer_id)
	if sid == 0:
		return -1
	return NetSession.seat_steam_id.find(sid)


## Headless test hook (see _ready()): stands in for a client's missing UI by
## submitting, for OUR seat only, whatever a bot would have played - through
## the exact same _perform()/RPC path a real drag-and-drop uses.
func _run_client_autoplay() -> void:
	var run_id := _game_id
	while game != null and not game.is_finished():
		if run_id != _game_id:
			return
		if _busy or _awaiting_ack:
			await _wait(0.02)
			continue
		var only_this_seat: Array = []
		for seat in game.num_players:
			if seat != human_seat:
				only_this_seat.append(seat)
		var action := Bot.pick(game, only_this_seat)
		if action.is_empty():
			await _wait(0.02)
			continue
		await _perform(action)
		if _is_authority():
			# on a real host this is _submit()'s job; this stand-in has to do
			# it too, or a bot seat whose turn follows ours never gets driven
			_run_bot_turns()


## An action dict carries a real CardData reference, which only means something
## on the peer that produced it - the wire form is suit/rank, unique per card.
func _action_to_wire(action: Dictionary) -> Dictionary:
	var wire := {type = action.type, player = action.player}
	if action.get("card") != null:
		wire.suit = action.card.suit
		wire.rank = action.card.rank
	if action.has("target"):
		wire.target = action.target
	return wire


## Reverses _action_to_wire() against this peer's own DurakGame: finds the
## matching entry in get_legal_actions(seat) so the resulting action carries a
## real CardData from THIS peer's mirror. Doubles as validation - a stale or
## fabricated wire action simply matches nothing and comes back empty.
func _resolve_wire_action(wire: Dictionary, seat: int) -> Dictionary:
	if seat < 0 or game == null:
		return {}
	for candidate in game.get_legal_actions(seat):
		if candidate.type != wire.get("type"):
			continue
		if candidate.get("target", -1) != wire.get("target", -1):
			continue
		var wants_card: bool = wire.has("suit")
		if candidate.has("card") != wants_card:
			continue
		if wants_card and (candidate.card.suit != wire.suit or candidate.card.rank != wire.rank):
			continue
		return candidate
	return {}


# ---------------------------------------------------------------- action + animation

## Applies one action, then plays the resulting card movements as an ordered
## sequence: the played card first, then the table clearing (all beaten -> the
## discard, or the defender takes it), then each seat's refill from the talon in
## turn order. Ends by settling every sprite to the true final layout.
func _apply_and_animate(action: Dictionary) -> void:
	var run_id := _game_id
	_busy = true
	_waiting_for_human = false
	var before := _snapshot()
	var bout_attacker: int = game.attacker
	var bout_defender: int = game.defender

	game.apply_action(action)

	# sort every moved card into what happened to it
	var played: Array[CardData] = []
	var discarded: Array[CardData] = []
	var taken: Array[CardData] = []
	var taker := -1
	var refilled := {} # seat -> Array[CardData]
	var after := _snapshot()
	for card in after:
		var was: String = before.get(card, after[card])
		var now: String = after[card]
		if was == now:
			continue
		var from_hand := was.begins_with("hand:")
		if now == "table" and from_hand:
			played.append(card)
		elif now == "discard":
			if from_hand:
				played.append(card)
			discarded.append(card)
		elif now.begins_with("hand:") and (was == "table" or from_hand):
			if from_hand:
				played.append(card)
			taken.append(card)
			taker = now.substr(5).to_int()
		elif now.begins_with("hand:") and was == "talon":
			var seat := now.substr(5).to_int()
			refilled.get_or_add(seat, [] as Array[CardData]).append(card)

	# 1. the played card slides onto the table, from whoever's hand held it
	for card in played:
		var view: Sprite2D = _card_views.get(card)
		if view == null:
			view = _create_view(card)
			_card_views[card] = view
			var origin_seat := _zone_seat(before.get(card, ""))
			if origin_seat >= 0:
				view.position = _seat_layout(origin_seat).origin
		var slot := _table_target_for(card)
		view.z_index = slot.z
		_animate_to(view, slot.pos, slot.angle, _fit_scale(view, table_card_height), play_anim, 0.0)
	if not played.is_empty():
		_deal_burst(played.size())
		await _wait(play_beat)
		if run_id != _game_id: return

	# 2. clear the table
	if not discarded.is_empty():
		_play_fan()
		for card in discarded:
			_animate_view_away(card)
		_sync_back_stack(_discard_stack, mini(game.discard.size(), 5),
			discard_pos, discard_card_height, 1)
		await _wait(clear_beat)
		if run_id != _game_id: return
	elif not taken.is_empty():
		_play_fan()
		if taker == human_seat:
			for card in taken:
				var view: Sprite2D = _card_views.get(card)
				if view != null:
					_animate_to(view, _seat_layout(human_seat).origin, 0.0,
						_fit_scale(view, hand_card_height), clear_anim, 0.0)
		else:
			for card in taken:
				_animate_view_away(card)
			_grow_opponent_backs(taker)
		await _wait(clear_beat)
		if run_id != _game_id: return

	# 3. refill from the talon, one seat at a time, in the engine's refill order
	if not refilled.is_empty():
		for seat in _refill_order(bout_attacker, bout_defender):
			if not refilled.has(seat):
				continue
			if seat == human_seat:
				_draw_into_hand(seat)
			else:
				_grow_opponent_backs(seat)
			_deal_burst(refilled[seat].size())
			_sync_back_stack(_talon_stack, maxi(game.talon_count() - 1, 0),
				talon_pos, talon_card_height, -1)
			await _wait(refill_beat)
			if run_id != _game_id: return

	_busy = false
	if run_id != _game_id:
		return
	_resync() # 4. settle every sprite to the final layout and unlock input


func _wait(seconds: float) -> void:
	if _headless:
		await get_tree().process_frame
	else:
		await get_tree().create_timer(seconds).timeout


# ---------------------------------------------------------------- audio

func _init_audio() -> void:
	for i in range(1, 10):
		_deal_streams.append(load("res://audio/deal_%d.mp3" % i))
	for i in range(1, 4):
		_fan_streams.append(load("res://audio/card_fan_%d.mp3" % i))
	for _v in AUDIO_VOICES:
		var voice := AudioStreamPlayer.new()
		add_child(voice)
		_voices.append(voice)


func _play_stream(streams: Array[AudioStream], trim_db: float) -> void:
	if _headless or not sfx_enabled or streams.is_empty():
		return
	var voice := _voices[_voice_next]
	_voice_next = (_voice_next + 1) % _voices.size()
	voice.stream = streams[randi() % streams.size()]
	voice.volume_db = sfx_volume_db + trim_db
	voice.pitch_scale = randf_range(0.94, 1.06)
	voice.play()


## One card moved (played, drawn). Call once per card; for a group that moves
## together, `_deal_burst` spreads the clicks out.
func _play_deal() -> void:
	_play_stream(_deal_streams, 0.0)


## A whole pile moved at once - the defender picks the table up, or a beaten
## bout is swept to the discard.
func _play_fan() -> void:
	_play_stream(_fan_streams, 2.0)


## Fire-and-forget: `count` deal clicks, one every `deal_stagger` seconds, so a
## six-card refill from the talon rattles out instead of cracking as one sound.
func _deal_burst(count: int) -> void:
	if _headless or not sfx_enabled or count <= 0:
		return
	var n := mini(count, 12)
	for i in n:
		if not is_inside_tree():
			return
		_play_deal()
		if i < n - 1:
			await get_tree().create_timer(deal_stagger + randf() * 0.02).timeout


func _zone_seat(zone: String) -> int:
	return zone.substr(5).to_int() if zone.begins_with("hand:") else -1


func _snapshot() -> Dictionary:
	# CardData -> zone tag: "talon" | "discard" | "table" | "hand:<seat>"
	var zones := {}
	for card in game.deck:
		zones[card] = "talon"
	for card in game.discard:
		zones[card] = "discard"
	for seat in game.num_players:
		for card in game.hands[seat]:
			zones[card] = "hand:%d" % seat
	for pair in game.table:
		zones[pair.attack] = "table"
		if pair.defense != null:
			zones[pair.defense] = "table"
	return zones


func _refill_order(first_attacker: int, bout_defender: int) -> Array[int]:
	# mirrors DurakGame._refill: attacker, then clockwise, defender last
	var order: Array[int] = []
	var seat := first_attacker
	for _step in game.num_players:
		order.append(seat)
		seat = (seat + 1) % game.num_players
	order.erase(bout_defender)
	order.append(bout_defender)
	return order


func _table_target_for(card: CardData) -> Dictionary:
	var count := game.table.size()
	for i in count:
		if game.table[i].attack == card:
			return {pos = _table_slot_pos(i, count, false), angle = 0.0, z = _table_z(i, false)}
		if game.table[i].defense == card:
			return {pos = _table_slot_pos(i, count, true), angle = 0.14, z = _table_z(i, true)}
	return {pos = BOARD_CENTER, angle = 0.0, z = 40} # bout already cleared; a brief flash at centre


func _draw_into_hand(seat: int) -> void:
	var hand: Array = game.hands[seat]
	for i in hand.size():
		var card: CardData = hand[i]
		if _card_views.has(card):
			continue
		var view := _create_view(card) # spawns at the talon
		_card_views[card] = view
		_animate_to(view, _hand_slot_pos(i, hand.size()), 0.0,
			_fit_scale(view, hand_card_height), refill_anim, i * 0.04)


func _grow_opponent_backs(seat: int) -> void:
	if seat == _near_seat():
		return
	if not _opponent_backs.has(seat):
		_opponent_backs[seat] = []
	var backs: Array = _opponent_backs[seat]
	var wanted: int = game.hands[seat].size()
	var facing: float = _seat_layout(seat).facing
	while backs.size() < wanted:
		backs.append(_new_back(talon_pos, 4))
	for i in backs.size():
		_animate_to(backs[i], _opponent_slot_pos(seat, i, wanted), facing,
			_fit_scale(backs[i], opponent_card_height), refill_anim, 0.0)


func _fit_scale(view: Sprite2D, target_height: float) -> Vector2:
	return Vector2.ONE * (target_height / maxf(view.texture.get_height(), 1.0))


# ---------------------------------------------------------------- human actions

func _human_actions() -> Array:
	if human_seat < 0 or game == null or game.is_finished():
		return []
	return game.get_legal_actions(human_seat)


func _submit(action: Dictionary) -> void:
	if _busy or _awaiting_ack:
		return # a move is already animating, or ours is in flight to the host
	_turn_epoch += 1 # pre-empt the bot loop so it doesn't act on top of us
	_drag = {}
	_hovered_view = null
	_move_pending = false
	await _perform(action)
	if _is_authority():
		_run_bot_turns()


## Lay one attack card down but keep the turn on the human's side: the bots
## don't move until _on_confirm(), so you can throw several same-rank cards in
## one go. A card on the table can't be taken back - it lives in game.table, so
## _rebuild_input_targets() never re-lists it as draggable.
func _play_local(action: Dictionary) -> void:
	if _busy or _awaiting_ack:
		return
	_turn_epoch += 1
	_drag = {}
	_hovered_view = null
	# set before the await: _apply_and_animate() ends with _resync(), which is
	# what puts the Confirm button on screen - it has to see the flag already set
	_move_pending = true
	await _perform(action)
	if _is_authority() and _human_actions().is_empty():
		_release_to_bots() # nothing left to add - hand over on its own


## End the human's staged move and let the bots run. A non-defender attacker
## must formally "pass", or the engine keeps the bout open waiting on them.
func _release_to_bots() -> void:
	_move_pending = false
	_update_buttons() # drop Confirm now, don't wait for the next resync
	if game != null and not game.is_finished():
		for action in _human_actions():
			if action.type == "pass":
				await _perform(action)
				break
	if _is_authority():
		_run_bot_turns()


func _on_confirm() -> void:
	if _busy or _awaiting_ack or not _move_pending:
		return
	_release_to_bots()


func _on_take() -> void:
	for action in _human_actions():
		if action.type == "take":
			_submit(action)
			return


func _on_pass() -> void:
	for action in _human_actions():
		if action.type == "pass":
			_submit(action)
			return


## Purely a local display preference - never touches game.hands, so it can't
## affect legality, animation, or (in multiplayer) what gets sent over the wire.
func _on_hand_sort_pressed() -> void:
	_hand_sort = "suit" if _hand_sort == "rank" else "rank"
	_hand_sort_button.text = "Sort: %s" % _hand_sort.capitalize()
	if not _busy:
		_resync() # re-fan the hand right away; otherwise the next _resync() picks it up


# ---------------------------------------------------------------- drag & drop

func _unhandled_input(event: InputEvent) -> void:
	if game != null and game.is_finished():
		if event is InputEventKey and event.pressed and event.keycode in \
			[KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
			_restart()
		return
	if not _waiting_for_human or _awaiting_ack:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_drag()
		else:
			_end_drag()


func _begin_drag() -> void:
	if not _drag.is_empty():
		return
	var mouse := get_global_mouse_position()
	for i in range(_hand_slots.size() - 1, -1, -1):
		var slot: Dictionary = _hand_slots[i]
		if slot.playable and _hand_slot_rect(slot).has_point(mouse):
			_stop_tween(slot.view)
			_drag = {
				view = slot.view, card = slot.card, home_pos = slot.home_pos,
				grab_offset = mouse - slot.view.global_position,
			}
			slot.view.z_index = 100
			return


func _end_drag() -> void:
	if _drag.is_empty():
		return
	var mouse := get_global_mouse_position()
	var actions := _human_actions()

	# 1. dropped onto a specific unbeaten attack -> defend it.
	# Defence commits straight away: it is one card per attack, and the bout
	# needs the bots to answer between beats.
	for open_attack in _open_attack_views:
		if _view_rect(open_attack.view).grow(14).has_point(mouse):
			for action in actions:
				if action.type == "defend" and action.card == _drag.card \
						and action.target == open_attack.table_index:
					_submit(action)
					return

	# 2. dropped on the translate strip -> pass the attack on
	if _translate_strip.visible and translate_strip_rect.has_point(mouse):
		for action in actions:
			if action.type == "translate" and action.card == _drag.card:
				_submit(action)
				return

	# 3. dropped anywhere on the table -> attack / throw in
	if table_drop_rect.has_point(mouse):
		for action in actions:
			if action.type == "attack" and action.card == _drag.card:
				_play_local(action)
				return

	# 4. no valid target -> let _process glide the card home
	var view: Node2D = _drag.view
	_drag = {}
	if is_instance_valid(view):
		view.z_index = 0


func _process(_delta: float) -> void:
	if _hand_slots.is_empty():
		return

	var mouse := get_global_mouse_position()
	var dragging: bool = not _drag.is_empty()

	if dragging and is_instance_valid(_drag.view):
		var dragged: Node2D = _drag.view
		dragged.global_position = dragged.global_position.lerp(
			mouse - _drag.grab_offset, drag_follow)
		dragged.z_index = 100

	# a move is animating: the choreography owns every card, and _hand_slots may
	# still point at a hand view it is about to free. Leave the hand alone.
	if _busy:
		return

	# hover / raise only when the human can actually act; the fan still settles below
	var interactive: bool = _waiting_for_human and not dragging and not _awaiting_ack
	_hovered_view = null
	if interactive:
		for i in range(_hand_slots.size() - 1, -1, -1):
			if _hand_slot_rect(_hand_slots[i]).has_point(mouse):
				_hovered_view = _hand_slots[i].view
				break

	# settle every hand card onto its fan slot each frame - position, tilt, scale
	# and z - so the hand never freezes mid-pose when the turn passes to the bots
	for idx in _hand_slots.size():
		var slot: Dictionary = _hand_slots[idx]
		if not is_instance_valid(slot.view):
			continue # stale entry from a restart / bailed coroutine; next resync fixes it
		var view: Node2D = slot.view
		if dragging and view == _drag.view:
			continue
		var raised: bool = view == _hovered_view and slot.playable
		# lift perpendicular to the fan so a tilted card rises straight off the arc
		var lift := Vector2(sin(slot.home_angle), -cos(slot.home_angle)) * hover_raise
		var goal: Vector2 = slot.home_pos + (lift if raised else Vector2.ZERO)
		# hovered: lean toward the cursor (Balatro-style); otherwise rest on the fan arc
		var target_angle: float = slot.home_angle
		if raised:
			var lean := clampf((mouse.x - view.global_position.x) / 110.0, -1.0, 1.0)
			target_angle = deg_to_rad(hover_tilt) * lean
		view.global_position = view.global_position.lerp(goal, hand_follow)
		view.scale = view.scale.lerp(
			slot.home_scale * (hover_scale if raised else 1.0), hand_follow)
		view.rotation = lerp_angle(view.rotation, target_angle, hand_follow)
		view.z_index = 60 if raised else 10 + idx


# stable hit-box for a hand card, using its resting slot (not its current tween pose)
func _hand_slot_rect(slot: Dictionary) -> Rect2:
	var size: Vector2 = slot.view.texture.get_size() * slot.home_scale
	return Rect2(slot.home_pos - size * 0.5, size)


func _view_rect(view: Node2D) -> Rect2:
	var size: Vector2 = view.texture.get_size() * view.scale
	return Rect2(view.global_position - size * 0.5, size)


# ---------------------------------------------------------------- layout

func _near_seat() -> int:
	return human_seat if human_seat >= 0 else 0


func _seat_layout(seat: int) -> Dictionary:
	# origin: where this seat's cards sit. vertical: the back row runs down, not
	# across. facing: the angle the seat's cards rest at - the side seats hold
	# theirs sideways, turned to look towards that player.
	var relative := (seat - _near_seat() + game.num_players) % game.num_players
	match relative:
		0: return {origin = Vector2(960, 965), vertical = false, facing = 0.0, label_offset = Vector2(-45, -150)}
		1: return {origin = Vector2(150, 540), vertical = true, facing = - PI / 2.0, label_offset = Vector2(-40, -170)}
		2: return {origin = Vector2(960, 120), vertical = false, facing = 0.0, label_offset = Vector2(-45, 90)}
		_: return {origin = Vector2(1770, 540), vertical = true, facing = PI / 2.0, label_offset = Vector2(-40, -170)}


# The human hand is a fan: cards ride a circle of radius `hand_fan_radius`
# whose centre sits that far below the seat origin, so the middle card stays
# on the origin and the rest sweep out along the arc. A large radius flattens
# the fan back toward a straight row.
func _hand_fan_step(hand_size: int) -> float:
	# arc-length spacing / radius = angle between adjacent cards (radians),
	# with a clamp so big hands still fit across the screen
	var spacing := minf(hand_card_spacing, 1100.0 / maxf(hand_size, 1))
	return spacing / maxf(hand_fan_radius, 1.0)


func _hand_slot_angle(index: int, hand_size: int) -> float:
	return (index - (hand_size - 1) * 0.5) * _hand_fan_step(hand_size)


func _hand_slot_pos(index: int, hand_size: int) -> Vector2:
	var pivot: Vector2 = _seat_layout(_near_seat()).origin + Vector2(0, hand_fan_radius)
	var angle := _hand_slot_angle(index, hand_size)
	return pivot + hand_fan_radius * Vector2(sin(angle), -cos(angle))


## `seat`'s hand arranged per _hand_sort, for fanning out the human's own hand.
## A display order only - a duplicate array, so game.hands itself (and thus
## legality, animation diffing, and what a client sends over the wire) never
## depends on how the cards happen to be arranged on screen.
func _display_hand(seat: int) -> Array:
	var hand: Array = game.hands[seat].duplicate()
	if _hand_sort == "suit":
		hand.sort_custom(func(a: CardData, b: CardData) -> bool:
			return [a.suit, a.rank] < [b.suit, b.rank])
	else: # "rank"
		hand.sort_custom(func(a: CardData, b: CardData) -> bool:
			return [a.rank, a.suit] < [b.rank, b.suit])
	return hand


func _opponent_slot_pos(seat: int, index: int, hand_size: int) -> Vector2:
	var layout := _seat_layout(seat)
	var spacing := 26.0
	var span := spacing * maxf(hand_size - 1, 0)
	var offset := -span * 0.5 + index * spacing
	return layout.origin + (Vector2(0, offset) if layout.vertical else Vector2(offset, 0))


func _table_slot_pos(index: int, attack_count: int, is_defense: bool) -> Vector2:
	var spacing := 165.0
	var left := BOARD_CENTER.x - spacing * maxf(attack_count - 1, 0) * 0.5
	var base := Vector2(left + index * spacing, BOARD_CENTER.y - 12)
	return base + (Vector2(30, 44) if is_defense else Vector2.ZERO)


# z_index bands: trump under the deck (1) < talon/discard backs (5) < hand (10)
# < table, where each defence sits one above the attack it beats
func _table_z(index: int, is_defense: bool) -> int:
	return 20 + index * 2 + (1 if is_defense else 0)


func _face_up_layout() -> Array:
	# every card that should currently be shown face up, with its target transform
	var layout: Array = []
	var hand: Array = _display_hand(_near_seat())
	for i in hand.size():
		layout.append({
			card = hand[i], pos = _hand_slot_pos(i, hand.size()),
			rotation = _hand_slot_angle(i, hand.size()), height = hand_card_height, z = 10 + i,
		})
	var attack_count := game.table.size()
	for i in attack_count:
		var pair: Dictionary = game.table[i]
		layout.append({
			card = pair.attack, pos = _table_slot_pos(i, attack_count, false),
			rotation = 0.0, height = table_card_height, z = _table_z(i, false),
		})
		if pair.defense != null:
			layout.append({
				card = pair.defense, pos = _table_slot_pos(i, attack_count, true),
				rotation = 0.14, height = table_card_height, z = _table_z(i, true),
			})
	if game.trump_card in game.deck:
		layout.append({
			card = game.trump_card, pos = talon_pos + Vector2(60, 0),
			rotation = PI * 0.5, height = talon_card_height, z = 1,
		})
	return layout


# ---------------------------------------------------------------- view sync

func _resync() -> void:
	if game == null:
		return
	# input is live whenever the human has any move - even if bots can also act,
	# so throw-ins can interleave instead of forcing a wait
	_waiting_for_human = not _human_actions().is_empty()

	var layout := _face_up_layout()
	var shown := {}
	var spawned := 0
	for entry in layout:
		shown[entry.card] = true
		var view: Sprite2D = _card_views.get(entry.card)
		var delay := 0.0
		if view == null:
			view = _create_view(entry.card)
			_card_views[entry.card] = view
			delay = spawned * 0.05
			spawned += 1
		view.z_index = entry.z
		var target_scale: Vector2 = Vector2.ONE \
			* (float(entry.height) / maxf(view.texture.get_height(), 1.0))
		_animate_to(view, entry.pos, entry.rotation, target_scale, move_duration, delay)

	# any card that had a face-up view but no longer belongs face up -> send it off
	for card in _card_views.keys():
		if not shown.has(card):
			_animate_view_away(card)

	_sync_back_stack(_talon_stack, maxi(game.talon_count() - 1, 0),
		talon_pos, talon_card_height, -1)
	_sync_back_stack(_discard_stack, mini(game.discard.size(), 5),
		discard_pos, discard_card_height, 1)
	_place_slots()
	_talon_label.text = "Talon  %d" % game.talon_count() if game.talon_count() > 0 else "Talon"
	_discard_label.text = "Discard  %d" % game.discard.size() if game.discard.size() > 0 else "Discard"
	_sync_opponents()

	_rebuild_input_targets()
	_update_status()
	_update_buttons()

	# _process drives the hand every frame (fan pose + hover); drop the settle
	# tween so the two don't fight over the same transform
	for slot in _hand_slots:
		_stop_tween(slot.view)


func _create_view(card: CardData) -> Sprite2D:
	var view := _instance_card()
	view.setup(CardData.SUIT_NAMES[card.suit], card.rank, true)
	view.position = _view_start_pos(card)
	view.scale = Vector2.ONE * (talon_card_height / maxf(view.texture.get_height(), 1.0))
	view.z_index = 10
	_card_layer.add_child(view)
	return view


func _view_start_pos(card: CardData) -> Vector2:
	# fly a newly shown card in from wherever it plausibly came from
	for i in game.table.size():
		if game.table[i].attack == card:
			return _seat_layout(game.attacker).origin
		if game.table[i].defense == card:
			return _seat_layout(game.defender).origin
	return talon_pos


func _animate_view_away(card: CardData) -> void:
	var view: Sprite2D = _card_views.get(card)
	if view == null:
		return # a card that briefly passed through the table without ever rendering
	_card_views.erase(card)
	var destination := talon_pos
	var destination_angle := 0.0
	if card in game.discard:
		destination = discard_pos
	else:
		for seat in game.num_players:
			if seat != _near_seat() and card in game.hands[seat]:
				destination = _seat_layout(seat).origin
				destination_angle = _seat_layout(seat).facing
				break
	_stop_tween(view)
	var tween := create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(view, "position", destination, clear_anim)
	tween.tween_property(view, "rotation", destination_angle, clear_anim)
	tween.tween_property(view, "scale", view.scale * 0.6, clear_anim)
	tween.tween_property(view, "modulate:a", 0.0, clear_anim)
	tween.chain().tween_callback(view.queue_free)


func _sync_back_stack(stack: Array, wanted: int, base: Vector2,
		card_height: float, lean: int) -> void:
	wanted = clampi(wanted, 0, 12)
	while stack.size() < wanted:
		stack.append(_new_back(base, 5))
	while stack.size() > wanted:
		_fade_out_and_free(stack.pop_back())
	for i in stack.size():
		var back: Sprite2D = stack[i]
		var back_scale := Vector2.ONE * (card_height / maxf(back.texture.get_height(), 1.0))
		_animate_to(back, base + Vector2(i * 1.6 * lean, -i * 1.9),
			0.0, back_scale, move_duration, 0.0)


func _sync_opponents() -> void:
	for seat in game.num_players:
		if seat == _near_seat():
			_seat_labels[seat].visible = human_seat >= 0
			if human_seat >= 0:
				_update_seat_label(seat)
			continue

		if not _opponent_backs.has(seat):
			_opponent_backs[seat] = []
		var backs: Array = _opponent_backs[seat]
		while backs.size() > game.hands[seat].size():
			_fade_out_and_free(backs.pop_back())
		_grow_opponent_backs(seat) # spawns any missing backs and re-homes them all
		_update_seat_label(seat)


func _update_seat_label(seat: int) -> void:
	var layout := _seat_layout(seat)
	var role := ""
	if not game.is_finished():
		if seat == game.attacker:
			role = "  ▶ attacker"
		elif seat == game.defender:
			role = "  ◀ defender"
	var who := "You" if seat == human_seat else "P%d" % seat
	var label := _seat_labels[seat]
	label.text = "%s   (%d)%s" % [who, game.hands[seat].size(), role]
	label.add_theme_color_override("font_color", Color.GOLD if role != "" else Color.WHITE)
	label.position = layout.origin + layout.label_offset


# ---------------------------------------------------------------- sprite helpers

func _instance_card() -> Sprite2D:
	return CARD_SCENE.instantiate()


func _new_back(pos: Vector2, z: int) -> Sprite2D:
	var back := _instance_card()
	back.setup("clubs", 6, false)
	back.position = pos
	back.z_index = z
	_card_layer.add_child(back)
	return back


func _animate_to(view: Node2D, pos: Vector2, angle: float,
		target_scale: Vector2, duration: float, delay: float) -> void:
	_stop_tween(view)
	var tween := create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(view, "position", pos, duration).set_delay(delay)
	tween.tween_property(view, "rotation", angle, duration).set_delay(delay)
	tween.tween_property(view, "scale", target_scale, duration).set_delay(delay)
	view.set_meta("tween", tween)


func _stop_tween(view: Node2D) -> void:
	if view.has_meta("tween"):
		var tween = view.get_meta("tween")
		if is_instance_valid(tween):
			tween.kill()
		view.remove_meta("tween")


func _fade_out_and_free(node: Node2D) -> void:
	_stop_tween(node)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(node, "modulate:a", 0.0, 0.22)
	tween.tween_property(node, "scale", node.scale * 0.7, 0.22)
	tween.chain().tween_callback(node.queue_free)


# ---------------------------------------------------------------- input targets / hud

func _rebuild_input_targets() -> void:
	_hand_slots.clear()
	_open_attack_views.clear()
	if human_seat < 0 or game.is_finished():
		return

	var hand: Array = _display_hand(human_seat)
	var playable := _playable_cards()
	for i in hand.size():
		var card: CardData = hand[i]
		var view: Sprite2D = _card_views.get(card)
		if view == null:
			continue
		var can_play: bool = playable.has(card)
		# a card the human can't play right now is dimmed; when there is no card
		# play at all (not your turn, or take/pass only) the whole hand dims, so
		# a bright hand always means "you can act here"
		view.modulate.a = 1.0 if can_play else 0.4
		_hand_slots.append({
			view = view, card = card, home_pos = _hand_slot_pos(i, hand.size()),
			home_angle = _hand_slot_angle(i, hand.size()),
			home_scale = Vector2.ONE * (hand_card_height / maxf(view.texture.get_height(), 1.0)),
			playable = can_play,
		})

	for i in game.table.size():
		if game.table[i].defense == null:
			var view: Sprite2D = _card_views.get(game.table[i].attack)
			if view != null:
				_open_attack_views.append({view = view, table_index = i})


func _playable_cards() -> Dictionary:
	var cards := {}
	for action in _human_actions():
		if action.has("card"):
			cards[action.card] = true
	return cards


func _update_status() -> void:
	if game.is_finished():
		_status_label.text = ""
		return
	var phase_name: String = ["ATTACK", "DEFEND", "TAKING", "OVER"][game.phase]
	var trump_rank: String = CardData.RANK_NAMES.get(
		game.trump_card.rank, str(game.trump_card.rank))
	var role := ""
	if human_seat == game.attacker:
		role = "     — YOU attack"
	elif human_seat == game.defender:
		role = "     — YOU defend"
	_status_label.text = "trump %s%s     %s     talon %d  discard %d%s" % [
		trump_rank, SUIT_GLYPHS[game.trump_suit], phase_name,
		game.talon_count(), game.discard.size(), role,
	]


func _update_buttons() -> void:
	var actions := _human_actions()
	var offered := func(action_type: String) -> bool:
		return actions.any(func(action): return action.type == action_type)
	# "Confirm" ends a staged attack and lets the bots run - it stands in for
	# "Pass" (only the attacking side stages, so a pass is always what's meant).
	_confirm_button.visible = _move_pending and not game.is_finished()
	_pass_button.visible = offered.call("pass") and not _move_pending
	_take_button.visible = offered.call("take") \
		and (game.phase == DurakGame.Phase.TAKING or _unbeaten_count() > 0)
	_translate_strip.visible = offered.call("translate")


func _unbeaten_count() -> int:
	var count := 0
	for pair in game.table:
		if pair.defense == null:
			count += 1
	return count
