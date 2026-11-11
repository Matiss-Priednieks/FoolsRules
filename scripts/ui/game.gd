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
@export_range(0.0, 2.5, 0.01) var special_move_anim := 0.85 ## a special effect visibly moving a card (Sift, Cull, ...) - deliberately slower than an ordinary play, so it doesn't blend into normal card traffic
@export_range(0.0, 2.5, 0.01) var special_move_beat := 0.6 ## hold after a special-effect move, so the toast text and the motion land together
@export_range(0.0, 1.0, 0.01) var deal_fly := 0.24 ## opening deal: one card's flight from the talon
@export_range(0.0, 0.5, 0.01) var deal_gap := 0.045 ## opening deal: gap between consecutive cards
@export_range(-1.5, 1.5, 0.05) var deal_bend := 0.6 ## opening deal: peak paper flex mid-flight (0 = off)
@export_range(0.0, 0.8, 0.01) var deal_player_beat := 0.10 ## opening deal: pause between one player's hand and the next
@export_range(0.0, 30.0, 0.5) var throw_in_seconds := 5.0 ## auto-pass a throw-in choice left untouched this long (0 disables)
@export_range(0.0, 60.0, 1.0) var draft_seconds := 30.0 ## auto-pick a random draft offer left untouched this long (spec 4.2; 0 disables)
@export_range(0.0, 60.0, 1.0) var special_choice_seconds := 15.0 ## auto-pick a random Palm/Singleout/Stack/Forge choice left untouched this long (0 disables) - no dedicated UI yet, see the roadmap

@export_group("Card feel")
@export_range(0.0, 160.0, 1.0) var hover_raise := 62.0 ## px a hovered hand card lifts
@export_range(1.0, 1.8, 0.01) var hover_scale := 1.18 ## size multiplier while hovered
@export_range(0.0, 40.0, 0.5) var hover_tilt := 0.0 ## deg of flat Z-spin a hovered card leans toward the cursor
@export_range(0.0, 60.0, 1.0) var hover_3d := 14.0 ## deg of fake-3D perspective tilt toward the cursor (card_fx.gdshader)
@export_range(0.0, 24.0, 0.5) var hover_float := 5.0 ## px of gentle idle drift while a card is raised
@export_range(0.05, 1.0, 0.01) var hand_follow := 0.30 ## how fast hand cards ease to their slot
@export_range(0.05, 1.0, 0.01) var drag_follow := 0.40 ## how fast a dragged card chases the cursor

@export_group("Hand fan")
@export_range(250.0, 5000.0, 10.0) var hand_fan_radius := 900.0 ## arc radius of the human hand; larger = flatter, smaller = deeper curve
@export_range(24.0, 160.0, 1.0) var hand_card_spacing := 98.0 ## gap between adjacent hand cards along the arc

@export_group("Card sizes (px tall)")
@export_range(40.0, 320.0, 1.0) var hand_card_height := 240.0
@export_range(40.0, 320.0, 1.0) var table_card_height := 200.0
@export_range(40.0, 320.0, 1.0) var talon_card_height := 140.0
@export_range(40.0, 320.0, 1.0) var opponent_card_height := 118.0
@export_range(40.0, 320.0, 1.0) var discard_card_height := 130.0

@export_group("Audio")
@export_range(0.0, 0.20, 0.005) var deal_stagger := 0.05 ## gap between clicks when several cards move at once


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
@export var confirm_pass_pos := Vector2(1520, 610) ## Confirm and Pass share this slot - only one is ever visible at once
@export var take_button_pos := Vector2(1520, 690)

var game: DurakGame

# --- persistent scene nodes (see game.tscn for the actual layout) ---------------
@onready var _slot_layer: Node2D = $SlotLayer # empty-pile outline markers, drawn behind the cards
@onready var _talon_marker: Line2D = $SlotLayer/TalonMarker
@onready var _discard_marker: Line2D = $SlotLayer/DiscardMarker
@onready var _card_layer: Node2D = $CardLayer # every card / back sprite lives here
@onready var _ui_layer: CanvasLayer = $UI
@onready var _ui_root: Control = $UI/Root # every Control below hangs off this one themed node
@onready var _turn_banner: Label = $UI/Root/TurnBanner # "YOUR MOVE" plate, only while you can act
@onready var _effect_toast: Label = $UI/Root/EffectToast # "Barbed refills P2 to 7 this round" etc.
@onready var _card_tooltip: VBoxContainer = $UI/Root/CardTooltip # hover boxes for a special card's effect(s)
@onready var _draft_overlay: Control = $UI/Root/DraftOverlay # centered, dims the board - spec 4.2 pauses everyone
@onready var _draft_title: Label = $UI/Root/DraftOverlay/Title
@onready var _draft_countdown: Label = $UI/Root/DraftOverlay/Countdown
@onready var _reserve_label: Label = $UI/Root/ReserveLabel # the human's own reserve (spec 4.1, owner-visible only)
@onready var _talon_label: Label = $UI/Root/TalonLabel
@onready var _discard_label: Label = $UI/Root/DiscardLabel
@onready var _seat_labels: Array[Label] = [
	$UI/Root/SeatLabel0, $UI/Root/SeatLabel1, $UI/Root/SeatLabel2, $UI/Root/SeatLabel3]
	## 4 in the scene; _ensure_seat_labels() grows the list for bigger tables.
@onready var _hand_sort_button: Button = $UI/Root/HandSortButton
@onready var _confirm_button: Button = $UI/Root/ConfirmButton
@onready var _take_button: Button = $UI/Root/TakeButton
@onready var _pass_button: Button = $UI/Root/PassButton
@onready var _deflect_strip: Panel = $UI/Root/DeflectStrip # ghost "pass" slot right of the attack row
@onready var _end_screen: ColorRect = $UI/Root/EndScreen
@onready var _end_title: Label = $UI/Root/EndScreen/EndTitle
@onready var _end_standings: Label = $UI/Root/EndScreen/EndStandings
@onready var _again_button: Button = $UI/Root/EndScreen/AgainButton
@onready var _menu_button: Button = $UI/Root/EndScreen/MenuButton
@onready var _pause_button: Button = $UI/Root/PauseButton
@onready var _pause_overlay: Control = $UI/Root/PauseOverlay
@onready var _pause_resume: Button = $UI/Root/PauseOverlay/Panel/Box/ResumeButton
@onready var _pause_restart: Button = $UI/Root/PauseOverlay/Panel/Box/RestartButton
@onready var _pause_quit: Button = $UI/Root/PauseOverlay/Panel/Box/QuitButton
@onready var _music_slider: HSlider = $UI/Root/PauseOverlay/Panel/Box/MusicRow/MusicSlider

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
var _draft_card_views: Dictionary = {} # CardData -> Sprite2D, the draft overlay's offered cards (rebuilt each resync)
var _ephemeral_views: Dictionary = {} # Sprite2D -> true, an in-flight _animate_special_move() view not otherwise tracked
var _draft_buttons: Array[Button] = [] # invisible click targets over _draft_card_views, same lifetime
var _reserve_draws_this_action: Dictionary = {} # card -> true, cards drawn from reserve (not talon) this _apply_and_animate() - tells _view_start_pos() where to fly them in from
var _drag := {} # {view, card, home_pos, grab_offset} while dragging
var _hovered_view: Node = null
var _headless := false
var _menu_open := false # the mid-game menu overlay is up; blocks board input, does NOT pause
var _throw_in_deadline := -1.0 # Time.get_ticks_msec()/1000.0 value; -1 = no throw-in timer running
var _draft_deadline := -1.0 # same, for a pending draft offer (spec 4.2)
var _special_choice_deadline := -1.0 # same, for a pending Palm/Singleout/Stack/Forge choice
var _hand_sort := "rank" # "rank" | "suit" - purely local display order, never touches game.hands

# --- audio ----------------------------------------------------------------


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if _headless:
		bot_delay = 0.0 # keep any headless run (smoke test or a --lan-* test) fast

	if _headless and not NetSession.active:
		human_seat = -1 # plain headless run: the self-play smoke test
	elif NetSession.active:
		human_seat = NetSession.local_seat # launched from a multiplayer lobby or LAN test
		var live := multiplayer.has_multiplayer_peer()
		print("[net] multiplayer game: seat=%d authority=%s live_peer=%s unique_id=%d status=%d" % [
			human_seat, _is_authority(), live,
			multiplayer.get_unique_id() if live else 0,
			multiplayer.multiplayer_peer.get_connection_status() if live else -1])
		SteamLobby.disconnected_unexpectedly.connect(_on_disconnected_unexpectedly)
		if not live and not _headless:
			# the peer never came up (see steam_lobby.gd _start_peer failure) -
			# don't drop the player into an unplayable board
			_on_disconnected_unexpectedly.call_deferred("Couldn't connect. Back to the menu.")
			return
		if _headless:
			# Neither a headless host nor a headless client has a UI to drag
			# cards with, so both need a stand-in for OUR seat specifically -
			# the host's own seat isn't a bot seat either. Goes through the
			# same _perform()/RPC path a real drag-and-drop would. Deferred:
			# _new_game() (called at the end of _ready()) hasn't built `game`
			# yet at this point.
			_run_client_autoplay.call_deferred()

	# the pause menu must draw over everything else in the UI, draft overlay included
	var pause := $UI/Root/PauseOverlay
	pause.get_parent().move_child(pause, -1)
	# chalk line marking where a drop counts as "on the table"
	var edge := $TableEdge as ColorRect
	edge.position = table_drop_rect.position
	edge.size = table_drop_rect.size
	(edge.material as ShaderMaterial).set_shader_parameter("rect_size", table_drop_rect.size)
	var px := get_node_or_null("Pixelate")
	if px:
		px.visible = pixelate_enabled and not _headless

	_set_slot_marker_points(_talon_marker, talon_card_height)
	_set_slot_marker_points(_discard_marker, discard_card_height)
	_place_slots()
	# these are tunable exports, not baked into the scene
	_confirm_button.position = confirm_pass_pos
	_pass_button.position = confirm_pass_pos
	_take_button.position = take_button_pos

	_hand_sort_button.pressed.connect(_on_hand_sort_pressed)
	_confirm_button.pressed.connect(_on_confirm)
	_take_button.pressed.connect(_on_take)
	_pass_button.pressed.connect(_on_pass)
	_again_button.pressed.connect(_restart)
	_menu_button.pressed.connect(_to_menu)
	_pause_button.pressed.connect(_open_menu)
	_pause_resume.pressed.connect(_close_menu)
	_pause_restart.pressed.connect(_restart)
	_pause_quit.pressed.connect(_to_menu)
	_music_slider.value = Music.volume
	_music_slider.value_changed.connect(Music.set_volume)

	RenderingServer.set_default_clear_color(Color(0.05, 0.22, 0.12))
	if _headless:
		_new_game() # tests / headless LAN runs: no pre-game screen, deal at once
	else:
		_pregame()


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
	for l in [_talon_label, _discard_label]:
		l.reset_size() # plates hug their text
	# talon plate sits above the deck (top-left corner is free; below it would
	# collide with the left seat's plate)
	_talon_label.position = talon_pos + Vector2(-_talon_label.size.x * 0.5 + 40.0,
		-talon_card_height * 0.5 - 18.0 - _talon_label.size.y)
	_discard_label.position = discard_pos + Vector2(-_discard_label.size.x * 0.5, discard_card_height * 0.5 + 14.0)


# ---------------------------------------------------------------- pre-game

## The pause between "play" and the deal, the same for both modes: a panel of
## seat plates (READY / LOADING... / BOT), then a short countdown, then the deal.
## Singleplayer waits for you to press Play (meanwhile the card shader is
## pre-compiled, so the first deal doesn't hitch). Multiplayer
## waits for every human: each client reports in once its board has loaded,
## the host shares who's ready and starts everyone's countdown together - so
## no client can miss the host's first moves while it's still loading.
@export_range(0.0, 10.0, 0.1) var pregame_seconds := 1.5 ## multiplayer: synced countdown once everyone's loaded
const PREGAME_TIMEOUT := 30.0 ## MP host: how long to wait on a slow loader before offering options

var _pregame_overlay: Control
## Read by the Transition autoload: hold the scene-change cover until this is
## true (board built + card shader warmed up), however long that takes here.
var reveal_ready := false
var _pregame_title: Label
var _pregame_rows: HFlowContainer
var _pregame_status: Label
var _pregame_actions: HBoxContainer
var _ready_seats := {} # seat -> true once that player's board has loaded
var _pregame_started := false
var _botified: Array = [] # MP: humans who never loaded, replaced by bots at start


func _pregame() -> void:
	_build_pregame_overlay()
	await _warm_up_card_shader()
	reveal_ready = true
	if not NetSession.active:
		# singleplayer: you start it - a Play button (Enter / Space work too)
		for seat in NetSession.num_players:
			_ready_seats[seat] = true
		_refresh_pregame_rows()
		_pregame_title.text = "Ready when you are"
		_pregame_status.text = ""
		var play := Button.new()
		play.text = "Play"
		play.custom_minimum_size = Vector2(240, 64)
		play.pressed.connect(func():
			if _pregame_started:
				return
			_pregame_started = true
			_run_countdown(0.0))
		_pregame_actions.add_child(play)
		_pregame_actions.visible = true
		play.grab_focus() # Enter / Space press it
	elif _is_authority():
		_ready_seats[human_seat] = true
		_host_check_ready()
		_host_wait_timeout()
	else:
		_refresh_pregame_rows()
		_client_announce_ready()


func _build_pregame_overlay() -> void:
	Sfx.fan(-6.0)
	_pregame_overlay = Control.new()
	_pregame_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_root.add_child(_pregame_overlay)
	_ui_root.move_child(_pregame_overlay, _pause_overlay.get_index()) # under the pause menu
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pregame_overlay.add_child(dim)
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PlatePanel"
	panel.custom_minimum_size = Vector2(640, 0)
	_pregame_overlay.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	panel.add_child(box)
	_pregame_title = Label.new()
	_pregame_title.theme_type_variation = &"Heading"
	_pregame_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pregame_title.text = "Waiting for players..." if NetSession.active else "Shuffling the deck..."
	box.add_child(_pregame_title)
	_pregame_rows = HFlowContainer.new()
	_pregame_rows.alignment = FlowContainer.ALIGNMENT_CENTER
	_pregame_rows.add_theme_constant_override("h_separation", 14)
	_pregame_rows.add_theme_constant_override("v_separation", 10)
	box.add_child(_pregame_rows)
	_pregame_status = Label.new()
	_pregame_status.theme_type_variation = &"Toast"
	_pregame_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_pregame_status)
	_pregame_actions = HBoxContainer.new()
	_pregame_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	_pregame_actions.add_theme_constant_override("separation", 16)
	_pregame_actions.visible = false
	box.add_child(_pregame_actions)
	for seat in NetSession.num_players:
		var plate := Label.new()
		plate.theme_type_variation = &"SeatPlate"
		_pregame_rows.add_child(plate)
	_refresh_pregame_rows()
	# centre once the containers have sized themselves
	await get_tree().process_frame
	panel.position = (Vector2(1920, 1080) - panel.size) * 0.5


func _seat_ready(seat: int) -> bool:
	return _ready_seats.has(seat) or (NetSession.active and seat < NetSession.seat_is_bot.size() \
		and NetSession.seat_is_bot[seat])


func _refresh_pregame_rows() -> void:
	if _pregame_rows == null:
		return
	for seat in _pregame_rows.get_child_count():
		var plate := _pregame_rows.get_child(seat) as Label
		var is_bot: bool = seat != human_seat and (not NetSession.active \
			or (seat < NetSession.seat_is_bot.size() and NetSession.seat_is_bot[seat]))
		var state := "BOT" if is_bot else ("READY" if _seat_ready(seat) else "LOADING...")
		plate.text = "%s  ·  %s" % [_display_name(seat), state]
		plate.theme_type_variation = &"SeatPlateDefend" if state == "READY" else &"SeatPlate"


## Draw one card (face + trump paths) invisibly so card_fx compiles now, under
## the loading screen, instead of hitching the opening deal.
func _warm_up_card_shader() -> void:
	var probe := _instance_card()
	probe.setup("hearts", 12, true)
	probe.set_trump_shimmer(true)
	probe.position = BOARD_CENTER
	probe.modulate.a = 0.02
	add_child(probe)
	for i in 3:
		await get_tree().process_frame
	probe.queue_free()


func _run_countdown(seconds := pregame_seconds) -> void:
	if NetSession.active:
		print("[net] pregame: everyone ready, counting down (bots for %s)" % [_botified])
	for seat in _botified:
		NetSession.seat_is_bot[seat] = true
	_pregame_actions.visible = false
	_pregame_title.text = "Shuffling the deck..." if not NetSession.active else "Everyone's in"
	_refresh_pregame_rows()
	var end := Time.get_ticks_msec() / 1000.0 + seconds
	while true:
		var left := end - Time.get_ticks_msec() / 1000.0
		if left <= 0.0:
			break
		_pregame_status.text = "Dealing in %d..." % ceili(left)
		_countdown_tick("pregame", left)
		await get_tree().process_frame
	var fade := create_tween()
	fade.tween_property(_pregame_overlay, "modulate:a", 0.0, 0.25)
	fade.tween_callback(_pregame_overlay.queue_free)
	_new_game()


# --- multiplayer handshake (host is the authority, same as for actions)

## Client: keep telling the host we're loaded until it starts the game - the
## host's own board may still be loading, and an RPC to a node that doesn't
## exist yet is simply lost.
func _client_announce_ready() -> void:
	while not _pregame_started and is_inside_tree():
		if _host_reachable():
			net_client_ready.rpc_id(1)
		await get_tree().create_timer(1.0).timeout


@rpc("any_peer", "call_remote", "reliable")
func net_client_ready() -> void:
	if not _is_authority():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _pregame_started: # already under way (e.g. they were replaced by a bot) - unstick them
		net_start.rpc_id(sender, _botified)
		return
	var seat := _seat_for_peer(sender)
	if seat >= 0 and not _ready_seats.has(seat):
		_ready_seats[seat] = true
		print("[net] pregame: seat %d loaded" % seat)
	_host_check_ready()


func _host_check_ready() -> void:
	_refresh_pregame_rows()
	if multiplayer.has_multiplayer_peer():
		net_ready_state.rpc(_ready_seats.keys())
	for seat in NetSession.num_players:
		if not _seat_ready(seat):
			_pregame_status.text = "Waiting for everyone's game to load..."
			return
	_host_start()


func _host_start() -> void:
	if _pregame_started:
		return
	_pregame_started = true
	if multiplayer.has_multiplayer_peer():
		net_start.rpc(_botified)
	_run_countdown()


## After PREGAME_TIMEOUT the host can stop waiting: play on with bots in the
## missing seats, or take everyone back to the menu.
func _host_wait_timeout() -> void:
	await get_tree().create_timer(PREGAME_TIMEOUT).timeout
	if _pregame_started or not is_inside_tree():
		return
	_pregame_status.text = "Someone's game hasn't loaded yet."
	var bots := Button.new()
	bots.text = "Play on with bots"
	bots.pressed.connect(func():
		for seat in NetSession.num_players:
			if not _seat_ready(seat):
				_botified.append(seat)
		_host_start())
	var back := Button.new()
	back.text = "Back to menu"
	back.pressed.connect(_to_menu)
	_pregame_actions.add_child(bots)
	_pregame_actions.add_child(back)
	_pregame_actions.visible = true


@rpc("authority", "call_remote", "reliable")
func net_ready_state(seats: Array) -> void:
	for seat in seats:
		_ready_seats[seat] = true
	_refresh_pregame_rows()


@rpc("authority", "call_remote", "reliable")
func net_start(botified: Array) -> void:
	if _pregame_started:
		return
	_pregame_started = true
	_botified = botified
	_run_countdown()


# ---------------------------------------------------------------- game lifecycle

func _new_game() -> void:
	if NetSession.active:
		print("[net] dealing")
	_game_id += 1
	_turn_epoch += 1
	_busy = false
	_move_pending = false
	_awaiting_ack = false
	# In multiplayer every peer must deal identically without transmitting the
	# deal itself, so they all build the same DurakGame from the same seed.
	var game_seed := NetSession.seed if NetSession.active else 0
	# NetSession.num_players is always meaningfully set now, singleplayer
	# included (configure_singleplayer() takes the table size the menu's
	# stepper picked) - not just for networked games.
	var players := NetSession.num_players
	# SpecialEffects is stateless (all randomness goes through game._rng), so a
	# fresh instance per peer stays sync-safe under the same seed.
	game = DurakGame.new(players, game_seed, SpecialEffects.new())
	_ensure_seat_labels(game.num_players)
	game.game_over.connect(_on_game_over)
	_deal_out() # animate the deal, then settle + hand off to the bots


## Counter-clockwise seat order (left -> top -> right -> home in screen terms),
## so the human's own hand fills last. Was hardcoded to the relative offsets
## [1, 2, 3, 0], which only ever produces 4 distinct seats - for any other
## player count the modulo wrapped two offsets onto the same seat (2 players:
## offsets 0 and 2 collide, so do 1 and 3), dealing that seat's whole hand
## twice and orphaning the first set of views. Generalized to every opponent
## in order, then the human last, which reduces to the exact same [1,2,3,0]
## sequence at 4 players.
func _deal_order() -> Array[int]:
	var order: Array[int] = []
	for relative in range(1, game.num_players):
		order.append((_near_seat() + relative) % game.num_players)
	order.append(_near_seat())
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
		label.visible = false # an empty label would still draw its plate
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
				_flex_in_flight(view, deal_fly)
			else:
				_opponent_backs.get_or_add(seat, [])
				var back := _new_back(talon_pos, 4)
				_opponent_backs[seat].append(back)
				# turns to face its seat mid-flight
				_animate_to(back, _opponent_slot_pos(seat, i, hand.size()),
					_seat_layout(seat).facing,
					_fit_scale(back, opponent_card_height * _opp_scale()), deal_fly, 0.0)
				_flex_in_flight(back, deal_fly)
			Sfx.deal()
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
	Transition.change_scene("res://scenes/menu.tscn")


## Mid-game menu overlay. The game keeps running underneath (bots move, cards
## animate) - the overlay just eats board input via its full-rect Control while
## it's up, so you can't drag or click a contextual button behind it.
func _open_menu() -> void:
	Sfx.fan(-6.0)
	_menu_open = true
	_drag = {} # drop any card being held
	_pause_restart.visible = not NetSession.active # no synced redeal in multiplayer
	_pause_overlay.visible = true


func _close_menu() -> void:
	_menu_open = false
	_pause_overlay.visible = false


## The host vanished, the RPC connection died, or a client mirror desynced -
## bail out instead of sitting there frozen with no feedback.
func _on_disconnected_unexpectedly(reason: String) -> void:
	NetSession.pending_message = reason
	NetSession.active = false
	if SteamLobby.in_lobby:
		SteamLobby.leave() # release the peer/socket so the next game can host
	Transition.change_scene("res://scenes/menu.tscn")


func _restart() -> void:
	if NetSession.active:
		_to_menu() # multiplayer has no redeal button yet
		return
	_close_menu()
	_pause_button.visible = true
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


## "1st"/"2nd"/"3rd"/"4th".."24th" - was a fixed 4-entry lookup table that
## indexed out of bounds (a runtime error) for any finish place at or past
## 5th, reachable in any 5+ player game (the menu allows up to
## DurakGame.MAX_PLAYERS = 24).
func _ordinal(n: int) -> String:
	if n % 100 in [11, 12, 13]:
		return "%dth" % n
	match n % 10:
		1: return "%dst" % n
		2: return "%dnd" % n
		3: return "%drd" % n
		_: return "%dth" % n


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
		_end_title.text = "You got out %s" % _ordinal(maxi(place, 0) + 1)
	else:
		_end_title.text = "%s is the durak" % _display_name(loser)
	var rows: Array[String] = []
	for i in game.finish_order.size():
		var seat: int = game.finish_order[i]
		var who := _display_name(seat)
		var outcome := "durak" if i == game.finish_order.size() - 1 else "safe"
		rows.append("%d.  %s  —  %s" % [i + 1, who, outcome])
	_end_standings.text = "\n".join(rows)
	_close_menu() # in case the game ended while the menu was up
	_pause_button.visible = false
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
		if NetSession.active and multiplayer.has_multiplayer_peer():
			_broadcast_applied(action)
	elif not _host_reachable():
		# no live channel to the host - don't throw "peer not connected", bail
		_awaiting_ack = false
		_on_disconnected_unexpectedly("Lost connection to the host.")
	else:
		_awaiting_ack = true
		net_request_action.rpc_id(1, _action_to_wire(action))
		_await_ack(action)


func _host_reachable() -> bool:
	var p := multiplayer.multiplayer_peer
	return p != null and not (p is OfflineMultiplayerPeer) \
		and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and 1 in multiplayer.get_peers()


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
		while _busy: # resolve against a settled state, not one mid-animation
			await get_tree().process_frame
		var entry: Dictionary = _incoming_requests.pop_front()
		var action := _resolve_wire_action(entry.wire, entry.seat)
		if not action.is_empty(): # else stale/illegal - the sender's watchdog will retry
			_turn_epoch += 1 # a network move pre-empts the bot loop same as a local one
			await _apply_and_animate(action)
			_broadcast_applied(action)
	_draining_requests = false
	_run_bot_turns()


## Host -> clients: the action just applied, plus a fingerprint of the resulting
## game state so a client can catch the instant its mirror drifts.
func _broadcast_applied(action: Dictionary) -> void:
	var wire := _action_to_wire(action)
	wire["fp"] = _state_fingerprint()
	net_apply_action.rpc(wire)


## Cheap, order-sensitive hash of everything a replayed action stream must keep
## identical across peers. Not the CardData identities - suit/rank multisets.
func _state_fingerprint() -> int:
	var parts: Array = [
		game.attacker, game.defender, game.phase,
		game.deck.size(), game.discard.size(), game.attack_limit,
	]
	parts.append_array(game.is_out)
	parts.append_array(game.finish_order)
	parts.append(game.passed.keys().size())
	for pair in game.table:
		parts.append(pair.attack.suit * 100 + pair.attack.rank)
		parts.append(-1 if pair.defense == null else pair.defense.suit * 100 + pair.defense.rank)
	for hand in game.hands:
		var ranks: Array = []
		for c in hand:
			ranks.append(c.suit * 100 + c.rank)
		ranks.sort()
		parts.append(ranks)
	return str(parts).hash()


func _state_debug() -> String:
	var sizes: Array = []
	for hand in game.hands:
		sizes.append(hand.size())
	return "atk=%d def=%d phase=%d talon=%d discard=%d out=%s finish=%s hands=%s table=%d" % [
		game.attacker, game.defender, game.phase, game.deck.size(), game.discard.size(),
		game.is_out, game.finish_order, sizes, game.table.size()]


## The host -> everyone broadcast of an action it just applied. Runs on clients.
@rpc("authority", "call_remote", "reliable")
func net_apply_action(wire: Dictionary) -> void:
	_incoming_broadcasts.append(wire)
	if not _draining_broadcasts:
		_drain_incoming_broadcasts()


func _drain_incoming_broadcasts() -> void:
	_draining_broadcasts = true
	while not _incoming_broadcasts.is_empty():
		while _busy: # apply each broadcast against a settled mirror, in order
			await get_tree().process_frame
		var wire: Dictionary = _incoming_broadcasts.pop_front()
		var seat: int = wire.get("player", -1)
		var action := _resolve_wire_action(wire, seat)
		if seat == human_seat:
			_awaiting_ack = false
		if action.is_empty():
			push_error("[net] DESYNC: can't apply host action %s | %s" % [wire, _state_debug()])
			_bail_desync()
			return
		await _apply_and_animate(action)
		if wire.has("fp") and int(wire.fp) != _state_fingerprint():
			push_error("[net] DESYNC after %s: host fp=%d mine=%d | %s" % [
				wire, int(wire.fp), _state_fingerprint(), _state_debug()])
			_bail_desync()
			return
	_draining_broadcasts = false


func _bail_desync() -> void:
	_draining_broadcasts = false
	_incoming_broadcasts.clear()
	_on_disconnected_unexpectedly("Desynced from the host — returning to the menu.")


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
##
## Serialized: two of these must never overlap or their game.apply_action()
## calls interleave and the mirrors desync. Every caller (the bot loop, both
## RPC drain loops, the local input paths) funnels through this one wait.
func _apply_and_animate(action: Dictionary) -> void:
	while _busy:
		await get_tree().process_frame
	var run_id := _game_id
	_busy = true
	_waiting_for_human = false
	var before := _snapshot()

	game.apply_action(action)
	# Captured immediately - apply_action() clears effect_log at its own next
	# call, and a bot's next move could come before this one finishes animating.
	if not game.effect_log.is_empty():
		_flash_effect(game.effect_log.duplicate())
	# Mirror's peeks (spec 5, Sleight) are seat-scoped, not a table-wide toast -
	# only show the ones meant for this client's own seat.
	var mine_to_see: Array[String] = []
	for entry in game.private_log:
		if entry.seat == human_seat:
			mine_to_see.append("[peek] " + entry.text)
	if not mine_to_see.is_empty():
		_flash_effect(mine_to_see)

	# sort every moved card into what happened to it
	var played: Array[CardData] = []
	var discarded: Array[CardData] = []
	var taken: Array[CardData] = []
	var taker := -1
	var refilled := {} # seat -> Array[CardData]
	var special_moved: Array[Dictionary] = [] # {card, from, to} - a special relocated a card outside the ordinary flow
	var burned_now: Array[Dictionary] = [] # {card, from} - out of the game for good (Flame Hazard, Purge)
	var stuck_moved: Array[CardData] = [] # Spilt Samogon sticking to / coming back off the table edge
	_reserve_draws_this_action.clear()
	var after := _snapshot()
	for card in after:
		var was: String = before.get(card, after[card])
		var now: String = after[card]
		if was == now:
			continue
		var from_hand := was.begins_with("hand:")
		var was_on_table := was == "table"
		if now == "burned":
			burned_now.append({card = card, from = was})
		elif now == "stuck" or was == "stuck":
			stuck_moved.append(card) # glides to the table edge / back onto the table
		elif now == "table" and from_hand:
			played.append(card)
		elif now == "discard" and was_on_table:
			discarded.append(card)
		elif now.begins_with("hand:") and was_on_table:
			taken.append(card)
			taker = now.substr(5).to_int()
		elif now.begins_with("hand:") and (was == "talon" or was.begins_with("reserve:")):
			var seat := now.substr(5).to_int()
			refilled.get_or_add(seat, [] as Array[CardData]).append(card)
			# A reserve draw (the queued drafted card) moves exactly like a
			# talon draw logically, but should visibly fly in from the reserve
			# panel, not the talon, so it actually reads as "drawn from your
			# reserve" instead of looking like nothing happened.
			if was.begins_with("reserve:"):
				_reserve_draws_this_action[card] = true
		else:
			# A special effect moved this card outside the ordinary play/clear/
			# refill flow (Sift: discard -> talon; Cull: hand -> discard;
			# Holdout: discard -> hand; Tithe/Palm: hand -> discard/hand) -
			# flagged for its own slower, flashier animation (see
			# _animate_special_move()) instead of blending into normal traffic.
			special_moved.append({card = card, from = was, to = now})

	# 0. a card I just drafted flies from the draft overlay onto my shelf
	if human_seat >= 0:
		var shelf: Array = game.reserves[human_seat]
		for i in shelf.size():
			var card: CardData = shelf[i]
			if before.has(card) or _card_views.has(card):
				continue
			var view := _create_view(card)
			var from: Sprite2D = _draft_card_views.get(card)
			if from != null and is_instance_valid(from):
				view.global_position = from.global_position
			_card_views[card] = view
			_animate_to(view, _shelf_slot_pos(i), _shelf_tilt(card), _fit_scale(view, SHELF_CARD_HEIGHT),
				special_move_anim, 0.0)
			Sfx.deal()

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
		Sfx.deal_burst(played.size(), deal_stagger)
		await _wait(play_beat)
		if run_id != _game_id: return

	# 1.25 Spilt Samogon: unstuck cards slide onto the table with the lead;
	# newly stuck ones slide off to the edge as the table clears
	for card in stuck_moved:
		var view: Sprite2D = _card_views.get(card)
		if view == null:
			continue
		var target := {pos = view.position, angle = 0.0, height = table_card_height}
		for entry in _face_up_layout():
			if entry.card == card:
				target = {pos = entry.pos, angle = entry.rotation, height = entry.height}
		_animate_to(view, target.pos, target.angle, _fit_scale(view, target.height), special_move_anim, 0.0)
	if not stuck_moved.is_empty():
		await _wait(special_move_beat)
		if run_id != _game_id: return

	# 1.5 burned cards go up in flames where they are, before the table clears
	if not burned_now.is_empty():
		for entry in burned_now:
			_animate_burn(entry.card, entry.from)
		await _wait(burn_beat)
		if run_id != _game_id: return

	# 2. clear the table
	if not discarded.is_empty():
		Sfx.fan()
		for card in discarded:
			_animate_view_away(card)
		_sync_back_stack(_discard_stack, mini(game.discard.size(), 5),
			discard_pos, discard_card_height, 1)
		await _wait(clear_beat)
		if run_id != _game_id: return
	elif not taken.is_empty():
		Sfx.fan()
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

	# 2.5. special effects visibly relocate a card - Sift, Cull, and future ones
	if not special_moved.is_empty():
		for entry in special_moved:
			_animate_special_move(entry.card, entry.from, entry.to)
		await _wait(special_move_beat)
		if run_id != _game_id: return

	# 3. refill from the talon, one seat at a time, in the engine's refill order
	if not refilled.is_empty():
		for seat in _refill_order():
			if not refilled.has(seat):
				continue
			if seat == human_seat:
				_draw_into_hand(seat)
			else:
				_grow_opponent_backs(seat)
			Sfx.deal_burst(refilled[seat].size(), deal_stagger)
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

## Countdown tick: a pen click on each of a timer's last TICK_FROM seconds.
## `key` names the timer, so each one tracks its own last-ticked second.
const TICK_FROM := 5
var _last_tick := {}
func _countdown_tick(key: String, remaining: float) -> void:
	var sec := ceili(remaining)
	if sec != _last_tick.get(key, -1) and sec > 0 and sec <= TICK_FROM:
		Sfx.click()
	_last_tick[key] = sec


func _zone_seat(zone: String) -> int:
	return zone.substr(5).to_int() if zone.begins_with("hand:") else -1


func _snapshot() -> Dictionary:
	# CardData -> zone tag: "talon" | "discard" | "table" | "hand:<seat>" | "reserve:<seat>"
	var zones := {}
	for card in game.deck:
		zones[card] = "talon"
	for card in game.discard:
		zones[card] = "discard"
	for seat in game.num_players:
		for card in game.hands[seat]:
			zones[card] = "hand:%d" % seat
		for card in game.reserves[seat]:
			zones[card] = "reserve:%d" % seat
	for card in game.burned:
		zones[card] = "burned"
	for entry in game.stuck:
		zones[entry.card] = "stuck"
	for pair in game.table:
		zones[pair.attack] = "table"
		if pair.defense != null:
			zones[pair.defense] = "table"
	return zones


## The exact order the engine just refilled seats in - not re-derived here,
## since a raw "(seat+1) % num_players" walk gets it wrong once Scramble/
## Turnabout have touched the engine's seating indirection (_turn_order/
## _turn_direction). See DurakGame.last_refill_order's own doc comment.
func _refill_order() -> Array[int]:
	return game.last_refill_order


func _table_target_for(card: CardData) -> Dictionary:
	var count := game.table.size()
	for i in count:
		var j := _table_jitter(card)
		if game.table[i].attack == card:
			return {pos = _table_slot_pos(i, count, false) + Vector2(j.x, j.y), angle = j.z, z = _table_z(i, false)}
		if game.table[i].defense == card:
			return {pos = _table_slot_pos(i, count, true) + Vector2(j.x, j.y), angle = 0.14 + j.z, z = _table_z(i, true)}
	return {pos = BOARD_CENTER, angle = 0.0, z = 40} # bout already cleared; a brief flash at centre


func _draw_into_hand(seat: int) -> void:
	var hand: Array = game.hands[seat]
	for i in hand.size():
		var card: CardData = hand[i]
		if _card_views.has(card):
			continue
		var view := _create_view(card) # spawns at the talon, or the reserve panel if drawn from there
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
			_fit_scale(backs[i], opponent_card_height * _opp_scale()), refill_anim, 0.0)


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

func _input(event: InputEvent) -> void:
	# the CRT autoload re-sends every mouse event bent to match the picture;
	# only act on that bent copy (this node sees the raw one first)
	if event is InputEventMouse and CRT.active() and not event.has_meta("crt"):
		return
	# a release always ends a drag - even over a button, which would otherwise
	# swallow it and leave the card stuck to the cursor until the next click
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press_at = Time.get_ticks_msec() / 1000.0
			_press_pos = _mouse()
			_long_pressed = false
		else:
			_press_at = -1.0
			if _long_pressed and _draft_overlay.visible:
				get_viewport().set_input_as_handled() # an info hold never picks a draft card
	if not _drag.is_empty() and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		get_viewport().set_input_as_handled()
		_end_drag()


## Touch: no hover, so card info (tooltips, the "why not" box, the hand lift)
## comes from holding a finger still on a card for LONG_PRESS seconds. Letting
## go where you pressed puts the card back - it never plays it.
const LONG_PRESS := 0.35
const LONG_PRESS_SLOP := 24.0 ## px the finger may wander and still count as held
var _touch := Display.touch()
var _press_at := -1.0 # when the current press began; -1 = no finger down
var _press_pos := Vector2.ZERO
var _long_pressed := false # this press turned into an info hold


func _holding() -> bool:
	if _press_at < 0.0 or _mouse().distance_to(_press_pos) > LONG_PRESS_SLOP:
		return false
	if Time.get_ticks_msec() / 1000.0 - _press_at >= LONG_PRESS:
		_long_pressed = true
	return _long_pressed


## The mouse in board space, through the CRT warp - use this, never
## get_global_mouse_position(): the root viewport reads that straight off the
## OS cursor, so it would skip the warp the CRT autoload applies to events.
func _mouse() -> Vector2:
	return CRT.warp(get_global_mouse_position())


func _unhandled_input(event: InputEvent) -> void:
	if game != null and game.is_finished():
		if event is InputEventKey and event.pressed and event.keycode in \
			[KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
			_restart()
		return
	if event.is_action_pressed("ui_cancel"): # Esc toggles the mid-game menu
		_close_menu() if _menu_open else _open_menu()
		return
	if _board_blocked() or not _waiting_for_human or _awaiting_ack:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_drag()
		else:
			_end_drag()


func _begin_drag() -> void:
	if not _drag.is_empty():
		return
	var mouse := _mouse()
	for i in range(_hand_slots.size() - 1, -1, -1):
		var slot: Dictionary = _hand_slots[i]
		var hit := _card_hit(slot.view, mouse) if slot.view == _hovered_view else _hand_slot_rect(slot).has_point(mouse)
		if slot.playable and hit:
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
	var mouse := _mouse()
	var actions := _human_actions()
	# Released back over the hand (or a plain click on a hand card) = changed
	# your mind: never a play, even where table_drop_rect overlaps the fan.
	if _over_hand(mouse):
		actions = []

	# 1. dropped onto a specific unbeaten attack -> beat it (or Rebound it).
	# Defence commits straight away: it is one card per attack, and the bout
	# needs the bots to answer between beats.
	for open_attack in _open_attack_views:
		if _view_rect(open_attack.view).grow(14).has_point(mouse):
			for kind in ["defend", "rebound"]:
				for action in actions:
					if action.type == kind and action.card == _drag.card and action.target == open_attack.table_index:
						_submit(action)
						return

	# 2. defender, free table space (or the ghost "pass" slot) -> pass the
	# attack on. Table cards are masked: a drop on/near one that couldn't
	# beat it (step 1) just goes home instead of being read as a pass.
	var on_pass_slot := _deflect_strip.visible and _deflect_strip.get_global_rect().has_point(mouse)
	if on_pass_slot or (table_drop_rect.has_point(mouse) and not _over_table_card(mouse)):
		for action in actions:
			if action.type == "deflect" and action.card == _drag.card:
				_submit(action)
				return

	# 3. attackers: anywhere on the table -> attack / throw in
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


## True if `point` is at or below the top of the human's fanned hand.
func _over_hand(point: Vector2) -> bool:
	for slot in _hand_slots:
		if is_instance_valid(slot.view) and point.y >= _hand_slot_rect(slot).position.y:
			return true
	return false


## True if `point` is on (or within a hair of) any card on the table.
func _over_table_card(point: Vector2) -> bool:
	for pair in game.table:
		for card in [pair.attack, pair.defense]:
			var view: Sprite2D = _card_views.get(card) if card != null else null
			if view != null and _view_rect(view).grow(14).has_point(point):
				return true
	return false


const EFFECT_TOAST_SECONDS := 2.2 ## how long each queued effect message shows, one at a time

var _effect_queue: Array[String] = []
var _effect_toast_until := 0.0


## Queues the special-card catalogue's effect log to show over the table, one
## message at a time (dev-quality visible feedback, same spirit as the name
## band on the card itself - a placeholder for real presentation, not the
## final UI). Empty in vanilla play.
func _flash_effect(messages: Array[String]) -> void:
	for msg in messages:
		_effect_queue.append(_localize_seat_names(msg))


func _update_effect_toast() -> void:
	if _effect_toast == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _effect_toast.text != "" and now > _effect_toast_until:
		_effect_toast.text = ""
	if _effect_toast.text == "" and not _effect_queue.is_empty():
		_effect_toast.text = _effect_queue.pop_front()
		_effect_toast_until = now + EFFECT_TOAST_SECONDS


## Hover tooltip for any visible special card (spec 9: "hover tooltips for full
## effect text"). Scans _card_views directly rather than the hand-only hover
## state below, since it should also work for table cards, opponents' revealed
## cards, and outside the human's own turn - anywhere a special is actually
## showing its face.
func _update_card_tooltip() -> void:
	if _card_tooltip == null:
		return
	if not _menu_open and (not _touch or _holding()):
		var mouse := _mouse()
		# _draft_card_views second: the draft overlay sits on top of everything
		# else when it's up, so its cards should win the hover check first.
		for views in [_draft_card_views, _card_views]:
			for card in views:
				var view: Sprite2D = views[card]
				if not is_instance_valid(view) or view.texture == null or not view.visible:
					continue
				var special: StringName = card.special if card.is_special() and SpecialCards.exists(card.special) else &""
				# the "why not" box: my hand only, never during the draft
				var why := _unplayable_reason(card) if is_same(views, _card_views) and not _draft_overlay.visible and _hand_slots.any(
					func(sl): return sl.card == card and not sl.playable) else ""
				if special == &"" and why == "":
					continue
				if _view_rect(view).has_point(mouse):
					_build_card_tooltip(special, why)
					var tip_size := _card_tooltip.get_combined_minimum_size()
					var pos := mouse + Vector2(20, 24)
					if _touch: # above the finger, not under it
						pos = mouse - Vector2(tip_size.x * 0.5, tip_size.y + 140.0)
					pos = pos.max(Vector2(20, 20))
					pos.x = minf(pos.x, 1920.0 - tip_size.x - 20.0)
					pos.y = minf(pos.y, 1080.0 - tip_size.y - 20.0)
					_card_tooltip.position = pos
					_card_tooltip.z_index = 10
					_card_tooltip.visible = true
					return
	_card_tooltip.visible = false


## Hover tooltip boxes come from CardInfo (shared with the Card Archive).
## Rebuilt only when the hovered special changes.
var _tooltip_for := ""


## `why` (if any) adds a "Can't play" box under the special's own boxes.
func _build_card_tooltip(id: StringName, why := "") -> void:
	var key := "%s|%s" % [id, why]
	if key == _tooltip_for:
		return
	_tooltip_for = key
	for child in _card_tooltip.get_children():
		_card_tooltip.remove_child(child)
		child.queue_free()
	if id != &"":
		for box in CardInfo.boxes(id):
			_card_tooltip.add_child(box)
	if why != "":
		_card_tooltip.add_child(CardInfo.box("Can't play this", why, &"TooltipCard"))


## True exactly while the human has a "pass" among their legal actions - which
## only ever happens mid-bout, on the attacking side, never for the opening
## lead (no pass to give) or while defending (no pass action exists there
## either). Reusing "pass is legal" instead of tracking this separately means
## the sticky-pass rule above (durak_game.gd._reopen_pass_for_new_ranks) is
## also what reopens - and, on timeout, restarts - this timer for free.
func _human_has_throw_in_choice() -> bool:
	for action in _human_actions():
		if action.type == "pass":
			return true
	return false


## Auto-passes a throw-in choice the human hasn't acted on within
## throw_in_seconds, so one AFK or thinking-too-long player can't stall
## everyone else forever. Counts down only while the choice is actually live
## and interactive; anything that takes it off the table (they act, the bout
## resolves, the menu opens) clears the deadline, and it starts fresh next
## time _human_has_throw_in_choice() turns true again.
##
## "pass" is legally offered to an attacking seat the whole time the bout is
## open, including while the defender is still mid-defence with cards still
## unbeaten - so without this extra guard the clock could run out (and
## auto-pass) before the defender even finished, then the table sweeps to
## discard the instant they do, never actually giving anyone their 5 seconds
## to throw in against the fully-answered table. Only held back for that one
## case (Phase.DEFEND with something still unbeaten) - once the defender
## takes instead of defending, the existing "one more round of throw-ins
## before the pile is handed over" window starts the clock immediately, same
## as always.
const DRAG_GRACE_SECONDS := 2.0
func _update_throw_in_timer() -> void:
	var defender_still_working := game != null and game.phase == DurakGame.Phase.DEFEND \
		and _unbeaten_count() > 0
	if throw_in_seconds <= 0.0 or _busy or _menu_open or _awaiting_ack \
	or defender_still_working or not _human_has_throw_in_choice():
		_throw_in_deadline = -1.0
		if _pass_button.visible:
			_pass_button.text = "Pass"
		return

	var now := Time.get_ticks_msec() / 1000.0
	if _throw_in_deadline < 0.0:
		_throw_in_deadline = now + throw_in_seconds

	var remaining := _throw_in_deadline - now
	_pass_button.text = "Pass (%d)" % ceili(maxf(remaining, 0.0))
	_countdown_tick("throw_in", remaining)
	if remaining <= 0.0:
		# a card mid-drag at the buzzer gets DRAG_GRACE_SECONDS to land (covers
		# lag too); past that the timeout wins, so holding can't stall forever
		if not _drag.is_empty() and remaining > -DRAG_GRACE_SECONDS:
			return
		_throw_in_deadline = -1.0
		for action in _human_actions():
			if action.type == "pass":
				_submit(action)
				return


func _draft_pick_actions() -> Array:
	return _human_actions().filter(func(a): return a.type == "draft_pick")


func _special_choice_actions() -> Array:
	return _human_actions().filter(func(a): return a.type == "special_choice")


## Spec 4.2: "short timer; on expiry, a random one of the three is auto-picked
## (never nothing)". Random here is a client-local UI decision, not engine
## state - it just becomes a normal submitted action, so it doesn't need
## game._rng the way an effect's own randomness would.
func _update_draft_timer() -> void:
	var offers := _draft_pick_actions()
	if draft_seconds <= 0.0 or _busy or _menu_open or _awaiting_ack or offers.is_empty():
		_draft_deadline = -1.0
		if _draft_countdown != null:
			_draft_countdown.text = ""
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _draft_deadline < 0.0:
		_draft_deadline = now + draft_seconds

	var remaining := _draft_deadline - now
	if _draft_countdown != null:
		_draft_countdown.text = "auto-picks in %d..." % ceili(maxf(remaining, 0.0))
	_countdown_tick("draft", remaining)
	if remaining <= 0.0:
		_draft_deadline = -1.0
		_submit(offers[randi() % offers.size()])


## No dedicated UI yet for Palm/Singleout/Stack/Forge's targeting (choosing an
## opponent, a talon order, a source card) - see the roadmap. Auto-picking
## random on a timeout keeps a human seat from freezing the whole table (this
## pause blocks everyone, same as a draft pick) until real UI lands.
func _update_special_choice_timer() -> void:
	var choices := _special_choice_actions()
	if special_choice_seconds <= 0.0 or _busy or _menu_open or _awaiting_ack or choices.is_empty():
		_special_choice_deadline = -1.0
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _special_choice_deadline < 0.0:
		_special_choice_deadline = now + special_choice_seconds
		return
	_countdown_tick("special", _special_choice_deadline - now)
	if now >= _special_choice_deadline:
		_special_choice_deadline = -1.0
		_submit(choices[randi() % choices.size()])


func _process(_delta: float) -> void:
	_update_effect_toast()
	_update_card_tooltip()
	_update_throw_in_timer()
	_update_draft_timer()
	_update_special_choice_timer()
	_update_draft_hover()

	if _hand_slots.is_empty():
		return

	var mouse := _mouse()
	var dragging: bool = not _drag.is_empty()

	if dragging and is_instance_valid(_drag.view):
		var dragged: Node2D = _drag.view
		dragged.global_position = dragged.global_position.lerp(
			mouse - _drag.grab_offset, drag_follow)
		if dragged.has_method("set_hover_tilt"):
			dragged.set_hover_tilt(0.0, 0.0) # flatten out as it lifts off the fan
			dragged.set_lifted(true, drag_follow)
		dragged.z_index = 100

	# a move is animating: the choreography owns every card, and _hand_slots may
	# still point at a hand view it is about to free. Leave the hand alone.
	if _busy:
		return

	# hover / raise only when the human can actually act; the fan still settles below
	var interactive: bool = _waiting_for_human and not dragging and not _awaiting_ack and not _board_blocked() \
		and (not _touch or _press_at >= 0.0)
	# the hovered card keeps hover anywhere over where it's actually drawn now
	# (raised, enlarged, fan-rotated) - not just its smaller resting slot
	var prev := _hovered_view
	_hovered_view = null
	var prev_for_sound := prev
	if interactive:
		if is_instance_valid(prev) and _hand_slots.any(func(sl): return sl.view == prev) and _card_hit(prev, mouse):
			_hovered_view = prev
		else:
			for i in range(_hand_slots.size() - 1, -1, -1):
				if _hand_slot_rect(_hand_slots[i]).has_point(mouse):
					_hovered_view = _hand_slots[i].view
					break

	# only cards you can play respond (lift + click); a dead card just gets
	# its "why not" tooltip
	if _hovered_view != null and _hovered_view != prev_for_sound 			and _hand_slots.any(func(sl): return sl.view == _hovered_view and sl.playable):
		Sfx.hover()

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
		if interactive and slot.playable and not raised:
			goal += lift * (PLAYABLE_RISE / hover_raise) # usable cards ride a touch higher
		var target_angle: float = slot.home_angle
		var tilt_x := 0.0
		var tilt_y := 0.0
		if raised:
			var lean_x := clampf((mouse.x - view.global_position.x) / 110.0, -1.0, 1.0)
			var lean_y := clampf((mouse.y - view.global_position.y) / 150.0, -1.0, 1.0)
			target_angle = deg_to_rad(hover_tilt) * lean_x # subtle flat in-plane lean, kept
			# the real depth: a perspective tilt toward the cursor, warped in card_fx.gdshader
			tilt_x = deg_to_rad(hover_3d) * -lean_y # cursor above centre -> top edge tips forward
			tilt_y = deg_to_rad(hover_3d) * lean_x # cursor right of centre -> right edge tips forward
			# never dead still while raised: a slow drift + a hair of tilt sway,
			# phase-offset per card so a fanned hand doesn't pulse in unison
			var t := Time.get_ticks_msec() * 0.001
			goal += Vector2(sin(t * 1.7 + idx), cos(t * 2.3 + idx)) * hover_float
			tilt_x += sin(t * 1.3 + idx) * 0.012
			tilt_y += cos(t * 1.1 + idx) * 0.012
		view.global_position = view.global_position.lerp(goal, hand_follow)
		view.scale = view.scale.lerp(
			slot.home_scale * (hover_scale if raised else 1.0), hand_follow)
		view.rotation = lerp_angle(view.rotation, target_angle, hand_follow)
		if view.has_method("set_hover_tilt"):
			view.set_hover_tilt(tilt_x, tilt_y, hand_follow)
			view.set_lifted(raised, hand_follow)
		view.z_index = 60 if raised else 10 + idx


const PLAYABLE_RISE := 16.0 ## px a playable hand card sits above the rest during your move


## Why `card` (in my hand) can't be played right now - shown as a tooltip on
## hover. Mirrors durak_game's legality checks; "" when it's simply not my move.
func _unplayable_reason(card: CardData) -> String:
	if not _waiting_for_human or human_seat < 0:
		return ""
	var joker := card.special == &"joker" or card.rank == CardData.JOKER_RANK
	if game.phase == DurakGame.Phase.DEFEND and human_seat == game.defender:
		if card.status == &"frozen":
			return "Frozen - it can't defend until it thaws."
		if card.status == &"irradiated":
			return "Irradiated - it can't defend until it wears off."
		if joker:
			return "The Joker can't be your last card."
		if not game._can_play_defense(card):
			return "This card can't be used to defend."
		return "Doesn't beat anything on the table - you need a higher card of the same suit, or a trump."
	if joker:
		return "The Joker only defends - it can't attack or be thrown in."
	if game._throw_in_locked.has(human_seat):
		return "Muzzled - you can't throw in this round."
	if game.table.is_empty():
		return "This card can't lead an attack."
	if card.status == &"frozen":
		return "Frozen - it can lead, but not be thrown in."
	if not game._can_add_attack(human_seat):
		return "The table's full - the defender can't take any more."
	var ranks: Array = game._table_ranks()
	if not ranks.has(card.rank):
		ranks.sort()
		var names := ranks.map(func(r): return CardData.RANK_NAMES.get(r, str(r)))
		return "Only ranks already on the table can be thrown in: %s." % ", ".join(names)
	return "This card can't be thrown in right now."


## Draft offers get the same life as hand cards: an idle bob/sway always, and
## the hovered one lifts, grows and tilts in 3D toward the cursor.
func _update_draft_hover() -> void:
	if _draft_card_views.is_empty() or not _draft_overlay.visible:
		return
	var mouse := _mouse()
	var t := Time.get_ticks_msec() * 0.001
	var idx := 0
	for card in _draft_card_views:
		var view: Sprite2D = _draft_card_views[card]
		idx += 1
		if not is_instance_valid(view):
			continue
		var home: Vector2 = view.get_meta("home_pos")
		var home_scale: Vector2 = view.get_meta("home_scale")
		var half := view.texture.get_size() * home_scale * 0.5
		# a hovered card stays hovered over its whole drawn (lifted, enlarged) area
		var hovered := _card_hit(view, mouse) if view.z_index == 5 else Rect2(home - half, half * 2.0).has_point(mouse)
		var bob := Vector2(sin(t * 1.4 + idx * 2.1), cos(t * 1.9 + idx * 1.3)) * 4.0
		var idle := Vector2(sin(t * 1.2 + idx), cos(t * 0.9 + idx)) * 0.015
		if hovered and view.z_index != 5:
			Sfx.hover()
		view.hover_follow(mouse, hovered, home + bob, home_scale, hand_follow,
			hover_scale, hover_raise * 0.5, hover_3d, idle)
		view.z_index = 5 if hovered else 0


## True if `point` is on the card as it's drawn right now: its full transform
## (position, scale, fan rotation), not an axis-aligned box.
func _card_hit(view: Node2D, point: Vector2) -> bool:
	if not is_instance_valid(view) or view.texture == null:
		return false
	var local: Vector2 = view.get_global_transform().affine_inverse() * point
	var half: Vector2 = view.texture.get_size() * 0.5
	return Rect2(-half, half * 2.0).has_point(local)


# stable hit-box for a hand card, using its resting slot (not its current tween pose)
func _hand_slot_rect(slot: Dictionary) -> Rect2:
	var size: Vector2 = slot.view.texture.get_size() * slot.home_scale
	return Rect2(slot.home_pos - size * 0.5, size)


func _view_rect(view: Node2D) -> Rect2:
	var size: Vector2 = view.texture.get_size() * view.scale
	return Rect2(view.global_position - size * 0.5, size)


# ---------------------------------------------------------------- layout

## True while board interaction should be suppressed for a reason other than
## an animation in flight (_busy) - the mid-game menu, or the draft overlay
## (spec 4.2 pauses everyone until the round's picks are all in).
func _board_blocked() -> bool:
	return _menu_open or (_draft_overlay != null and _draft_overlay.visible)


func _near_seat() -> int:
	return human_seat if human_seat >= 0 else 0


## The name to show for `seat`: "You" for the local human, a Steam username for
## anyone else with one (local or networked, single- or multiplayer -
## NetSession populates player_names/seat_is_bot the same way in every mode),
## "P<seat>" only as the bot/no-name fallback.
func _display_name(seat: int) -> String:
	if seat == human_seat:
		return "You"
	if seat < NetSession.seat_is_bot.size() and not NetSession.seat_is_bot[seat]:
		var name: String = NetSession.player_names[seat]
		if name != "":
			return name
	return "P%d" % seat


## Rewrites every "P<n>" seat reference in an engine-generated message (e.g.
## SpecialEffects' effect_log lines) to _display_name(n) - the engine only
## knows seat numbers, never player identity, by design (see durak_game.gd).
func _localize_seat_names(text: String) -> String:
	var result := text
	# Highest seat number first: "P10" contains "P1" as a literal substring, so
	# replacing P1 before P10 would corrupt it. A higher seat number is always
	# the longer (or equal) string, so descending order never has this problem.
	for seat in range(game.num_players - 1, -1, -1):
		result = result.replace("P%d" % seat, _display_name(seat))
	return result


func _seat_layout(seat: int) -> Dictionary:
	# origin: where this seat's cards sit. vertical: the back row runs down, not
	# across. facing: the rest angle - side seats hold theirs sideways, turned to
	# face that player. Self is fixed bottom-centre; the opponents ride an arc
	# swept over the top, spread evenly however many there are.
	var relative := (seat - _near_seat() + game.num_players) % game.num_players
	if relative == 0:
		return {origin = Vector2(960, 965), vertical = false, facing = 0.0, label_offset = Vector2(-45, -150)}
	var others := game.num_players - 1
	var t := 0.5 if others <= 1 else float(relative - 1) / float(others - 1)
	var theta := lerpf(-PI * 0.06, -PI * 0.94, t) # left edge -> over the top -> right edge
	var origin := Vector2(960.0 + cos(theta) * 780.0, 486.0 + sin(theta) * 360.0)
	var vertical := absf(cos(theta)) > 0.5
	return {
		origin = origin,
		vertical = vertical,
		facing = cos(theta) * (PI / 2.0),
		label_offset = Vector2(-40, -150) if vertical else Vector2(-45, 78),
	}


## Opponent fans get tighter as the table fills, so N of them still fit the arc.
func _opp_scale() -> float:
	return clampf(4.0 / maxf(game.num_players - 1, 1), 0.34, 1.0)


## The scene ships 4 seat labels; a bigger table needs more. Clone the styling
## of SeatLabel0 for any extra.
func _ensure_seat_labels(count: int) -> void:
	while _seat_labels.size() < count:
		var l := Label.new()
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.theme_type_variation = &"SeatPlate"
		_ui_root.add_child(l)
		_seat_labels.append(l)


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
	var spacing := 26.0 * _opp_scale()
	var span := spacing * maxf(hand_size - 1, 0)
	var offset := -span * 0.5 + index * spacing
	return layout.origin + (Vector2(0, offset) if layout.vertical else Vector2(offset, 0))


## Up to TABLE_ROW_MAX attacks share one centred row; past that the first
## TABLE_ROW_MAX stay on top and the newer ones form a second, centred row
## underneath. A defence sits offset down-right over the card it beats.
const TABLE_ROW_MAX := 6
func _table_slot_pos(index: int, attack_count: int, is_defense: bool) -> Vector2:
	var spacing := 205.0
	var two_rows := attack_count > TABLE_ROW_MAX
	var row := 1 if index >= TABLE_ROW_MAX else 0
	var in_row := attack_count
	if two_rows:
		in_row = TABLE_ROW_MAX if row == 0 else attack_count - TABLE_ROW_MAX
	var col := index - row * TABLE_ROW_MAX
	var left := BOARD_CENTER.x - spacing * maxf(in_row - 1, 0) * 0.5
	var y := BOARD_CENTER.y - 12.0
	if two_rows:
		y = 425.0 if row == 0 else 670.0
	return Vector2(left + col * spacing, y) + (Vector2(42, 62) if is_defense else Vector2.ZERO)


## A card on the table sits a little off-true, like a person put it down: a
## small offset and tilt, derived from the card itself so it never jitters
## frame to frame (purely visual - nothing here touches game state).
func _table_jitter(card: CardData) -> Vector3:
	var h := hash("%s%s%d" % [str(card), card.special, card.get_instance_id()])
	return Vector3(float(h % 13) - 6.0, float((h / 13) % 13) - 6.0, (float((h / 169) % 100) / 100.0 - 0.5) * 0.08)


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
		var aj := _table_jitter(pair.attack)
		layout.append({
			card = pair.attack, pos = _table_slot_pos(i, attack_count, false) + Vector2(aj.x, aj.y),
			rotation = aj.z, height = table_card_height, z = _table_z(i, false),
		})
		if pair.defense != null:
			var dj := _table_jitter(pair.defense)
			layout.append({
				card = pair.defense, pos = _table_slot_pos(i, attack_count, true) + Vector2(dj.x, dj.y),
				rotation = 0.14 + dj.z, height = table_card_height, z = _table_z(i, true),
			})
	# my reserve: a face-up shelf left of the hand - real cards, hoverable
	if human_seat >= 0:
		var shelf: Array = game.reserves[human_seat]
		for i in shelf.size():
			layout.append({
				card = shelf[i], pos = _shelf_slot_pos(i), rotation = _shelf_tilt(shelf[i]),
				height = SHELF_CARD_HEIGHT, z = 5 + i,
			})
	for i in game.stuck.size():
		layout.append({
			card = game.stuck[i].card, pos = _stuck_slot_pos(i),
			rotation = -0.18, height = table_card_height * 0.85, z = 15,
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
		# Refreshed every sync, not just at creation: Sift clears its own
		# special id the first time it's picked up, statuses wear off, etc.
		_dress(view, entry.card)
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
	_talon_label.text = "TALON  ·  %d     TRUMP %s" % [game.talon_count(), SUIT_GLYPHS[game.trump_suit]]
	_discard_label.text = "DISCARD  ·  %d" % game.discard.size()
	_place_slots()
	_sync_opponents()

	_rebuild_input_targets()
	_update_status()
	_update_buttons()
	_update_reserve_ui()
	for card in _card_views:
		var view: Sprite2D = _card_views[card]
		if is_instance_valid(view):
			_dress(view, card)
	_prune_orphan_card_views()

	# _process drives the hand every frame (fan pose + hover); drop the settle
	# tween so the two don't fight over the same transform
	for slot in _hand_slots:
		_stop_tween(slot.view)


## Everything a face-up card's look depends on beyond suit/rank - applied the
## moment a view exists, so a card in flight already looks like it will once it
## lands (no shimmer/status/glaze "pop" on arrival).
func _dress(view: Sprite2D, card: CardData) -> void:
	view.set_special(card.special)
	view.set_trump_shimmer(card.suit == game.trump_suit)
	view.set_status(card.status)
	view.set_sticky(game.stuck.any(func(e): return e.card == card))


func _create_view(card: CardData) -> Sprite2D:
	var view := _instance_card()
	view.setup(CardData.SUIT_NAMES[card.suit], card.rank, true)
	_dress(view, card)
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
	if _reserve_draws_this_action.has(card):
		return _reserve_label.position
	return talon_pos


func _animate_view_away(card: CardData) -> void:
	var view: Sprite2D = _card_views.get(card)
	if view == null:
		return # a card that briefly passed through the table without ever rendering
	_card_views.erase(card)
	_ephemeral_views[view] = true # mid-fade, untracked but not yet freed - exempt it from the orphan sweep
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
	tween.chain().tween_callback(func():
		_ephemeral_views.erase(view)
		view.queue_free())


## Screen position for a zone tag from _snapshot()/_apply_and_animate()'s diff -
## shared by _animate_special_move() so a special's source/destination doesn't
## need its own bespoke lookup per card.
## The reserve shelf: drafted cards, waiting to be drawn (oldest first, at the
## left - the next one your refill takes). Above the RESERVE plate, left of the
## hand; each card tilted a touch differently so it looks dropped, not filed.
const SHELF_CARD_HEIGHT := 130.0
func _shelf_slot_pos(i: int) -> Vector2:
	return Vector2(110.0 + i * 58.0, 700.0)


func _shelf_tilt(card: CardData) -> float:
	return (float(hash(str(card) + card.special) % 100) / 100.0 - 0.5) * 0.14


## Where stuck (Spilt Samogon) cards sit: tucked along the table's bottom-left
## edge, inside the chalk line, fanning right if there's more than one.
func _stuck_slot_pos(i: int) -> Vector2:
	return table_drop_rect.position + Vector2(90.0 + i * 70.0, table_drop_rect.size.y - 95.0)


func _zone_pos(zone: String) -> Vector2:
	if zone.begins_with("hand:"):
		return _seat_layout(zone.substr(5).to_int()).origin
	if zone.begins_with("reserve:"):
		return _reserve_label.position
	if zone == "discard":
		return discard_pos
	return talon_pos # "talon", or "table" (rare - specials don't currently pull a card off an unresolved table)


const burn_beat := 0.8 ## how long a burn plays before the table clears


## A card leaving the game for good burns away where it is: the tracked view
## if it has one (table, my hand), otherwise a temporary face-up one at its
## old spot. The burn itself is card_fx.gdshader's `burn` dissolve.
func _animate_burn(card: CardData, from_zone: String) -> void:
	var view: Sprite2D = _card_views.get(card)
	if view != null:
		_card_views.erase(card)
	else:
		view = _instance_card()
		view.setup(CardData.SUIT_NAMES[card.suit], card.rank, true)
		_dress(view, card)
		view.position = _zone_pos(from_zone)
		view.scale = Vector2.ONE * (table_card_height / maxf(view.texture.get_height(), 1.0))
		_card_layer.add_child(view)
	_stop_tween(view)
	view.z_index = 40
	_ephemeral_views[view] = true
	var tween := create_tween()
	tween.tween_method(view.set_burn, 0.0, 1.0, burn_beat)
	await tween.finished
	_ephemeral_views.erase(view)
	if is_instance_valid(view):
		view.queue_free()


## A card visibly relocated by a special effect, outside the ordinary play/
## clear/refill flow (Sift: discard -> talon; Cull: hand -> discard; future
## Holdout/Tithe/Palm moves) - see _apply_and_animate()'s `special_moved` list.
## Deliberately slower than a normal play (special_move_anim) with a gold
## flash at the midpoint, so it reads as "a special did this" rather than
## disappearing into the usual fast card traffic - the exact complaint that
## made Sift's recycling invisible before this existed (discard/talon aren't
## individually-tracked views, so without a dedicated flight there was nothing
## to animate at all).
func _animate_special_move(card: CardData, from_zone: String, to_zone: String) -> void:
	var to_near_hand := to_zone == "hand:%d" % _near_seat()
	var existing: Sprite2D = _card_views.get(card)

	if existing != null and not to_near_hand:
		# Was tracked as a face-up card (my own hand, or the table) and is
		# headed somewhere that shouldn't show it face-up anymore - discard,
		# the talon, or someone else's hand (Rebound spending itself; Palm
		# swapping my card to an opponent). Fade it and stop tracking it,
		# exactly like an ordinary pickup/discard - the bug this fixes left
		# the OLD view sitting fully opaque wherever it landed forever, while
		# a newer view (or none at all) occupied the same hand slot on top of
		# it: the "card underneath" a hovered hand card.
		_animate_view_away(card)
		return
	if existing == null and to_zone.begins_with("hand:") and not to_near_hand:
		return # arriving face-down in someone else's hand - nothing to show

	var view: Sprite2D = existing
	var ephemeral := view == null and not to_near_hand
	if view == null:
		view = _instance_card()
		view.setup(CardData.SUIT_NAMES[card.suit], card.rank, true)
		_dress(view, card)
		view.position = _zone_pos(from_zone)
		view.scale = Vector2.ONE * (talon_card_height / maxf(view.texture.get_height(), 1.0))
		view.z_index = 30
		_card_layer.add_child(view)
		if to_near_hand:
			_card_views[card] = view # keep tracking it - _resync() takes over as a normal hand card next
	_stop_tween(view)
	var target_scale := _fit_scale(view, hand_card_height if to_near_hand else talon_card_height)
	var tween := create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(view, "position", _zone_pos(to_zone), special_move_anim)
	tween.tween_property(view, "scale", target_scale, special_move_anim)
	view.set_meta("tween", tween)

	var flash := create_tween()
	flash.tween_property(view, "modulate", Color(1.6, 1.35, 0.5), special_move_anim * 0.35)
	flash.tween_property(view, "modulate", Color.WHITE, special_move_anim * 0.65)

	if ephemeral:
		_ephemeral_views[view] = true
		await tween.finished
		_ephemeral_views.erase(view)
		if is_instance_valid(view):
			view.queue_free()


## Belt-and-suspenders consistency check, run at the end of every _resync():
## every Sprite2D under _card_layer must be reachable from one of the
## tracking structures below, or an in-flight ephemeral animation. Anything
## else is a leak from some path that created a node without registering it
## (or failed to un-register one that left tracking) - freed outright rather
## than left to silently accumulate as a "ghost" card sitting on screen
## forever, uncounted and unplayable (the exact bug this was added to catch).
func _prune_orphan_card_views() -> void:
	var known := {}
	for view in _card_views.values():
		known[view] = true
	for view in _draft_card_views.values():
		known[view] = true
	for view in _ephemeral_views:
		known[view] = true
	for back in _talon_stack:
		known[back] = true
	for back in _discard_stack:
		known[back] = true
	for backs in _opponent_backs.values():
		for back in backs:
			known[back] = true
	for child in _card_layer.get_children():
		if not known.has(child):
			child.queue_free()


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


## Seat plates: a slanted, stencilled soot plate per player - name, card
## count, and the role. The look lives in the project theme (game_theme.tres:
## SeatPlate, and SeatPlateAttack / SeatPlateDefend for the role rim colours).
## Placed off the card fans so they never sit on cards: opponents above a side
## fan / below a top fan; your own sits bottom-left with your reserve, clear of
## the hand's hover lift.
func _update_seat_label(seat: int) -> void:
	var layout := _seat_layout(seat)
	var role := ""
	var plate := &"SeatPlate"
	if not game.is_finished():
		if seat == game.attacker:
			role = "ATTACKING"
			plate = &"SeatPlateAttack"
		elif seat == game.defender:
			role = "DEFENDING"
			plate = &"SeatPlateDefend"
	var label := _seat_labels[seat]
	label.text = "%s  ·  %d" % [_display_name(seat), game.hands[seat].size()]
	if seat != _near_seat() and not game.reserves[seat].is_empty():
		label.text += "  ·  RESERVE %d" % game.reserves[seat].size() # drafted specials they're holding
	if role != "":
		label.text += "   %s" % role
	label.theme_type_variation = plate
	label.visible = true
	label.reset_size()
	var size := label.get_combined_minimum_size()

	if seat == _near_seat():
		label.position = Vector2(24, 860)
		return
	var card_h := opponent_card_height * _opp_scale()
	var card_w := card_h * 500.0 / 726.0
	var span := 26.0 * _opp_scale() * maxf(game.hands[seat].size() - 1, 0)
	if layout.vertical: # side fan runs down, cards sideways: plate above its top end
		label.position = layout.origin + Vector2(-size.x * 0.5, -span * 0.5 - card_w * 0.5 - 12.0 - size.y)
	else: # top fan runs across: plate just below it
		label.position = layout.origin + Vector2(-size.x * 0.5, card_h * 0.5 + 10.0)


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
	if view.has_method("set_hover_tilt"):
		view.set_hover_tilt(0.0, 0.0) # drop any hover 3D-tilt before the card flies
		view.set_lifted(false)
	var tween := create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(view, "position", pos, duration).set_delay(delay)
	tween.tween_property(view, "rotation", angle, duration).set_delay(delay)
	tween.tween_property(view, "scale", target_scale, duration).set_delay(delay)
	view.set_meta("tween", tween)


## Bend the card up and back to flat over its flight. Peaks early (sqrt) to
## match _animate_to's ease-out - most of the travel happens up front. Bound
## to the view so it dies with it if the deal is interrupted.
func _flex_in_flight(view: Node2D, duration: float) -> void:
	if deal_bend == 0.0:
		return
	view.create_tween().tween_method(
		func(t: float): view.set_bend(sin(PI * sqrt(t)) * deal_bend), 0.0, 1.0, duration)


func _stop_tween(view: Node2D) -> void:
	if view.has_meta("tween"):
		var tween = view.get_meta("tween")
		if is_instance_valid(tween):
			tween.kill()
		view.remove_meta("tween")


func _fade_out_and_free(node: Node2D) -> void:
	_stop_tween(node)
	_ephemeral_views[node] = true # already popped off its tracking array by the caller - exempt from the orphan sweep
	var tween := create_tween().set_parallel(true)
	tween.tween_property(node, "modulate:a", 0.0, 0.22)
	tween.tween_property(node, "scale", node.scale * 0.7, 0.22)
	tween.chain().tween_callback(func():
		_ephemeral_views.erase(node)
		node.queue_free())


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
		# (opaque, not see-through: the fan's overlapping cards shouldn't ghost)
		view.modulate = Color.WHITE if can_play else Color(0.75, 0.75, 0.75, 0.8)
		# the stronger drained/shadowed look is reserved for genuine "your move,
		# but not with this card" moments - not when there's nothing to do at all
		view.set_invalid(_waiting_for_human and not can_play)
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


## The turn banner: a plate at the top of the table, shown only while it's
## actually your move - the one "loud" bit of HUD. Everything the old status
## line said (trump, pile counts, roles) now lives on the pile and seat plates.
func _update_status() -> void:
	var text := ""
	if not game.is_finished() and _waiting_for_human and not game._draft_pause_active() and not _human_actions().is_empty():
		match game.phase:
			DurakGame.Phase.SPECIAL_CHOICE:
				text = "YOUR MOVE  ·  CHOOSE"
			_:
				text = "YOUR MOVE  ·  DEFEND" if human_seat == game.defender else "YOUR MOVE  ·  ATTACK"
	_turn_banner.visible = text != ""
	if text == "":
		return
	_turn_banner.text = text
	_turn_banner.theme_type_variation = &"TurnBannerDefend" if human_seat == game.defender else &"TurnBannerAttack"
	_turn_banner.reset_size()
	_turn_banner.position = Vector2(960.0 - _turn_banner.size.x * 0.5, table_drop_rect.position.y + 14.0)


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
	# the ghost "pass" slot sits where the next table card would go, right of
	# the attack row - dropping anywhere free on the table also passes
	_deflect_strip.visible = offered.call("deflect")
	if _deflect_strip.visible:
		var size := Vector2(table_card_height * 500.0 / 726.0, table_card_height)
		_deflect_strip.size = size
		# where the next card would land (starting the second row at the 7th)
		var n := game.table.size()
		_deflect_strip.position = _table_slot_pos(n, n + 1 if n >= TABLE_ROW_MAX else n, false) - size * 0.5


const DRAFT_CARD_HEIGHT := 300.0 ## the draft overlay's offered cards are shown full-size, hoverable/clickable
const DRAFT_CARD_SPACING := 250.0

## Reserve panel + refill-choice row sit beside the human's own hand (spec
## 4.1, owner-visible only), still plain buttons. The draft row is different
## in kind, not just position: spec 4.2 pauses the *whole table* until every
## offer this round is claimed, so it's the centered, dimmed DraftOverlay -
## and its offers are shown as real card sprites (not buttons), reusing
## card.gd's own special-name band and _update_card_tooltip()'s hover, so a
## draft pick looks and inspects exactly like any other special in play.
func _update_reserve_ui() -> void:
	_reserve_label.visible = human_seat >= 0 and game != null
	if _reserve_label.visible:
		var names: Array = []
		for card in game.reserves[human_seat]:
			names.append(SpecialCards.DEFS[card.special].name)
		# the cards themselves sit on the shelf above - the plate is just its label
		_reserve_label.text = "RESERVE  ·  %d" % names.size() if not names.is_empty() else "RESERVE  ·  empty"
		_reserve_label.reset_size() # plate hugs its text

	# The overlay stays up for the *whole table's* draft pause (spec 4.2:
	# paused until everyone's chosen), not just while this seat's own pick is
	# outstanding - otherwise it'd vanish for you the moment you pick, even
	# though the game is still waiting on other players.
	var draft_actions := _draft_pick_actions()
	_draft_overlay.visible = game._draft_pause_active()
	_draft_title.text = "Waiting for other players..." if draft_actions.is_empty() else "Draft - pick one"
	_rebuild_draft_cards(draft_actions)


## Rebuilds the draft overlay's offered cards from scratch every call (there
## are never more than 4, so this is cheap): a real card sprite per offer, for
## the tooltip hover and the name band, plus an invisible click target the
## same size laid on top of it, since Sprite2D has no click signal of its own.
func _rebuild_draft_cards(actions: Array) -> void:
	for view in _draft_card_views.values():
		view.queue_free()
	_draft_card_views.clear()
	for b in _draft_buttons:
		b.queue_free()
	_draft_buttons.clear()

	var start_x := 960.0 - float(actions.size() - 1) * DRAFT_CARD_SPACING * 0.5
	for i in actions.size():
		var action: Dictionary = actions[i]
		var card: CardData = action.card
		var center := Vector2(start_x + i * DRAFT_CARD_SPACING, 610) # clear of the countdown even when hover-lifted

		var view := _instance_card()
		view.setup(CardData.SUIT_NAMES[card.suit], card.rank, true)
		_dress(view, card)
		view.scale = Vector2.ONE * (DRAFT_CARD_HEIGHT / maxf(view.texture.get_height(), 1.0))
		view.position = center
		view.set_meta("home_pos", center)
		view.set_meta("home_scale", view.scale)
		_draft_overlay.add_child(view)
		_draft_card_views[card] = view

		var hit_size: Vector2 = view.texture.get_size() * view.scale
		var hit := Button.new()
		hit.flat = true
		hit.modulate = Color(1, 1, 1, 0) # invisible - the card sprite underneath is the visual
		# covers the card's hovered pose too (scaled up + lifted), so a click on
		# the part that grew still picks it
		var grown := hit_size * hover_scale + Vector2(0, hover_raise * 0.5)
		hit.custom_minimum_size = grown
		hit.position = center - Vector2(grown.x * 0.5, hit_size.y * hover_scale * 0.5 + hover_raise * 0.5)
		hit.pressed.connect(func(): _submit(action))
		_draft_overlay.add_child(hit)
		_draft_buttons.append(hit)





func _unbeaten_count() -> int:
	var count := 0
	for pair in game.table:
		if pair.defense == null:
			count += 1
	return count
