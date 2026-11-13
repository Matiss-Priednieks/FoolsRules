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
@export_range(0.0, 3.0, 0.01) var stamp_beat := 1.1 ## how long the CLEARED stamp sits on a beaten table before it's swept
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
var _busy_since := 0.0 # when it went busy, for the stuck-animation watchdog
const BUSY_WATCHDOG := 20.0
var _waiting_for_human := false # the human has at least one legal move right now
var _move_pending := false # human has laid ≥1 card this turn, not yet released to the bots
var _awaiting_ack := false # multiplayer client: our own action is in flight to the host
var _hand_slots: Array = [] # [{view, card, home_pos, home_angle, home_scale, playable}]
var _open_attack_views: Array = [] # [{view, table_index}] for not-yet-beaten attacks
var _draft_card_views: Dictionary = {} # CardData -> Sprite2D, the draft overlay's offered cards (rebuilt each resync)
var _ephemeral_views: Dictionary = {} # Sprite2D -> true, an in-flight _animate_special_move() view not otherwise tracked
var _draft_buttons: Array[Control] = [] # invisible click targets over _draft_card_views, same lifetime
var _reserve_draws_this_action: Dictionary = {} # card -> true, cards drawn from reserve (not talon) this _apply_and_animate() - tells _view_start_pos() where to fly them in from
var _drag := {} # {view, card, home_pos, grab_offset} while dragging
var _hovered_view: Node = null
var _headless := false
var _menu_open := false # the mid-game menu overlay is up; blocks board input, does NOT pause
var _throw_in_deadline := -1.0 # Time.get_ticks_msec()/1000.0 value; -1 = no throw-in timer running
var _draft_deadline := -1.0 # same, for a pending draft offer (spec 4.2)
var _special_choice_deadline := -1.0 # same, for a pending Palm/Singleout/Stack/Forge choice
var _special_ui: SpecialUI # dossier, sealed folders, plate tags + intel chips
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
		print("[net] multiplayer game: seat=%d host=%s mode=%d" % [human_seat, _is_authority(), Net.mode])
		SteamLobby.disconnected_unexpectedly.connect(_on_disconnected_unexpectedly)
		Net.message.connect(_on_net_message)
		Net.member_left.connect(_on_member_left)
		Net.host_changed.connect(_on_host_changed)
		_last_host_key = Net.host_key()
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
	_special_ui = SpecialUI.new(self)
	_ui_root.add_child(_special_ui)
	_ui_root.move_child(_special_ui, _pause_overlay.get_index()) # under the pause menu
	_build_log()

	RenderingServer.set_default_clear_color(Color(0.05, 0.22, 0.12))
	if _headless and NetSession.active and _is_authority() and "--real-pregame" in OS.get_cmdline_user_args():
		_pregame() # test: the real ready-up/countdown a windowed host runs
	elif _headless and NetSession.active and not _is_authority():
		_client_announce_ready() # a headless guest asks the host in, same as a real one
	elif _headless:
		_pregame_started = true # no pre-game screen: a player who reports in just gets the move log
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
	if _pregame_overlay == null: # headless guest: no screen to count down on
		_new_game()
		return
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

## Client: keep telling the host we're loaded until it answers - its board
## may still be loading. It answers with "start" (everyone's in) or "sync"
## (the game's already going: here's every move so far).
func _client_announce_ready() -> void:
	while not _pregame_started and is_inside_tree():
		if Net.host_reachable():
			Net.send_to_host({t = "ready", seat = human_seat})
		await get_tree().create_timer(1.0).timeout


## Host: a player's board loaded. Before the start that's a ready-up; after it,
## they're late or coming back, so they get the whole game so far.
func _host_on_ready(sender: int, msg: Dictionary) -> void:
	var seat := _seat_of(sender, msg)
	if seat < 0:
		return
	if _pregame_started:
		Net.send_to(sender, {t = "sync", botified = _botified, bots = NetSession.seat_is_bot, log = _action_log})
		if NetSession.seat_is_bot[seat] and game != null:
			_set_seat_bot(seat, false) # back from a drop: their seat again
		return
	if not _ready_seats.has(seat):
		_ready_seats[seat] = true
		print("[net] pregame: seat %d loaded" % seat)
	_host_check_ready()


## Steam seats whose player isn't in the lobby any more (they left between
## Start and loading in) - nobody would ever hear about them leaving.
func _absent_seats() -> Array:
	var out: Array = []
	if Net.mode != Net.Mode.STEAM:
		return out
	var here: Array = SteamLobby.members.map(func(m): return m.steam_id)
	for seat in NetSession.num_players:
		var sid: int = NetSession.seat_steam_id[seat]
		if sid != 0 and not NetSession.seat_is_bot[seat] and sid not in here:
			out.append(seat)
	return out


func _host_check_ready() -> void:
	for seat in _absent_seats(): # gone before they loaded: a bot plays for them
		if seat not in _botified:
			_botified.append(seat)
		NetSession.seat_is_bot[seat] = true
	_refresh_pregame_rows()
	Net.broadcast({t = "ready_state", seats = _ready_seats.keys()})
	for seat in NetSession.num_players:
		if not _seat_ready(seat):
			if _pregame_status != null:
				_pregame_status.text = "Waiting for everyone's game to load..."
			return
	_host_start()


func _host_start() -> void:
	if _pregame_started:
		return
	_pregame_started = true
	Net.broadcast({t = "start", botified = _botified})
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


func _client_on_start(botified: Array) -> void:
	if _pregame_started:
		return
	_pregame_started = true
	_botified = botified
	_run_countdown()


## Late join / rejoin / a gap: the host's whole move log. A fresh board replays
## it instantly (no animation) and carries on from there.
func _client_on_sync(msg: Dictionary) -> void:
	var bots: Array = msg.get("bots", [])
	for seat in mini(bots.size(), NetSession.seat_is_bot.size()):
		NetSession.seat_is_bot[seat] = bool(bots[seat])
	NetSession.seat_is_bot[human_seat] = false
	var log: Array = msg.get("log", [])
	if msg.get("rebuild", false):
		_rebuilding = false
		_clear_board()
		_new_game(log)
		print("[net] rebuilt from the host's %d moves" % log.size())
		if _headless:
			_run_client_autoplay.call_deferred() # the test stand-in follows the new board
		return
	if not _pregame_started:
		_pregame_started = true
		_botified = msg.get("botified", [])
		if log.is_empty():
			_run_countdown() # the host is only just dealing - start like everyone else
			return
		if is_instance_valid(_pregame_overlay):
			_pregame_overlay.queue_free()
		_new_game(log)
		return
	_queue_acts(0, log) # already playing: it just fills whatever we're missing


# ---------------------------------------------------------------- game lifecycle

func _new_game(replay: Array = []) -> void:
	if NetSession.active:
		print("[net] dealing" if replay.is_empty() else "[net] rejoining: replaying %d moves" % replay.size())
	_action_log = []
	_incoming_acts.clear()
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
	_special_ui.reset()
	_ensure_seat_labels(game.num_players)
	game.game_over.connect(_on_game_over)
	if NetSession.active and _is_authority():
		for seat in _absent_seats(): # (a headless host deals without a pre-game check)
			_set_seat_bot.call_deferred(seat, true)
	if not replay.is_empty():
		for wire in replay:
			var action := _resolve_wire_action(wire, int(wire.get("player", -1)))
			if action.is_empty():
				push_error("[net] DESYNC replaying %s | %s" % [wire, _state_debug()])
				_bail_desync()
				return
			game.apply_action(action)
			_action_log.append(wire)
		_resync()
		_drain_incoming_acts()
		return
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
	_busy_since = Time.get_ticks_msec() / 1000.0

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
	if NetSession.active and SteamLobby.in_lobby and game != null and game.is_finished():
		SteamLobby.back_to_room() # match over: same lobby, another round
	elif NetSession.active:
		SteamLobby.leave() # no-op for a LAN test (never touched SteamLobby)
		Net.stop()
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
	_clear_board()
	_new_game()


## Every sprite and bit of board state gone, ready for a fresh _new_game().
func _clear_board() -> void:
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


func _on_game_over(loser: int) -> void:
	print("game over - durak is %s" % ("draw" if loser < 0 else "P%d" % loser))
	if DisplayServer.get_name() == "headless":
		if NetSession.active and _is_authority() and is_inside_tree():
			await get_tree().create_timer(3.0).timeout # let the last moves reach the guests
		if is_inside_tree():
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
	if NetSession.active and SteamLobby.in_lobby:
		_menu_button.text = "Back to lobby"
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
	if game == null:
		return # pre-game: nothing dealt yet
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
	return not NetSession.active or Net.is_host()


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
		if await _apply_and_animate(action) and NetSession.active:
			_broadcast_applied(action)
	elif not Net.host_reachable():
		_awaiting_ack = false
		_on_disconnected_unexpectedly("Lost connection to the host.")
	else:
		_awaiting_ack = true
		_pending_wire = _action_to_wire(action)
		Net.send_to_host({t = "req", w = _pending_wire})
		_await_ack(action)


## Defensive-only: a well-behaved host always answers. If it doesn't (a lost
## packet, a desync), unstick the client's input rather than freeze it forever.
func _await_ack(action: Dictionary) -> void:
	await get_tree().create_timer(6.0).timeout # real seconds, even headless (_wait() is one frame there)
	if not is_inside_tree():
		return
	if _awaiting_ack:
		push_warning("[net] host never answered a %s" % action.type)
		_awaiting_ack = false
		if not _busy: # mid-animation, the animation's own resync will settle it
			_resync()


## Every multiplayer message lands here. Requests and broadcasts are queued
## and drained one at a time: a message can arrive while the last move is
## still animating, and two applies must never interleave.
var _incoming_requests: Array = [] # host: [{wire, seat}] from players, arrival order
var _draining_requests := false
var _incoming_acts := {} # client: move number -> wire, waiting their turn
var _draining_acts := false
var _action_log: Array = [] # every move applied this game, in order (wire form) - rejoins replay it
var _pending_wire := {} # client: our own move, sent and not yet confirmed
var _asked_from := -1 # client: the move number we last asked the host to resend from
var _last_host_key := 0
var _applied_wire := {} # the last move _apply_and_animate applied, in wire form, described just before
var _net_trace := "--net-trace" in OS.get_cmdline_user_args() # print every move + fingerprint (desync hunting)
var _test_desync_at := -1 # -- --desync-at=<n>: corrupt this board after move n (tests the rebuild)


func _on_net_message(sender: int, msg: Dictionary) -> void:
	var from_host := sender == Net.host_key()
	match str(msg.get("t", "")):
		"ready":
			if _is_authority(): _host_on_ready(sender, msg)
		"ready_state":
			if from_host:
				for seat in msg.get("seats", []):
					_ready_seats[int(seat)] = true
				_refresh_pregame_rows()
		"start":
			if from_host: _client_on_start(msg.get("botified", []))
		"sync":
			if from_host: _client_on_sync(msg)
		"req":
			if _is_authority():
				var seat := _seat_of(sender, msg)
				if seat >= 0:
					_incoming_requests.append({wire = msg.get("w", {}), seat = seat, from = sender})
					if not _draining_requests:
						_drain_incoming_requests()
		"act":
			if from_host: _queue_acts(int(msg.get("n", -1)), [msg.get("w", {})])
		"resync": # a player drifted: the whole log, to rebuild from
			if _is_authority():
				Net.send_to(sender, {t = "sync", rebuild = true, botified = _botified,
					bots = NetSession.seat_is_bot, log = _action_log})
		"need":
			if _is_authority():
				var start := clampi(int(msg.get("from", 0)), 0, _action_log.size())
				Net.send_to(sender, {t = "fill", from = start, log = _action_log.slice(start)})
		"fill":
			if from_host: _queue_acts(int(msg.get("from", 0)), msg.get("log", []))
		"seat":
			if from_host: _set_seat_bot(int(msg.get("seat", -1)), bool(msg.get("bot", true)))
		"host": # a new host took over: line our move logs up
			if from_host: _client_on_new_host(sender, int(msg.get("n", 0)))
		"nack": # the host refused our move (stale or illegal)
			if from_host and _awaiting_ack:
				_awaiting_ack = false
				_pending_wire = {}
				if not _busy:
					_resync()
		"extra": # moves the new host missed from the old one
			if _is_authority(): _host_on_extra(int(msg.get("from", 0)), msg.get("log", []))


func _drain_incoming_requests() -> void:
	_draining_requests = true
	while not _incoming_requests.is_empty():
		while _busy and is_inside_tree(): # resolve against a settled state, not one mid-animation
			await get_tree().process_frame
		if not is_inside_tree():
			return
		var entry: Dictionary = _incoming_requests.pop_front()
		var action := _resolve_wire_action(entry.wire, entry.seat)
		if action.is_empty():
			# stale (they moved on an out-of-date board) or illegal: say so right
			# away, so their card goes home now instead of after the 6s watchdog
			Net.send_to(entry.from, {t = "nack", w = entry.wire})
			continue
		_turn_epoch += 1 # a network move pre-empts the bot loop same as a local one
		if await _apply_and_animate(action):
			_broadcast_applied(action)
		else:
			Net.send_to(entry.from, {t = "nack", w = entry.wire})
	_draining_requests = false
	_run_bot_turns()


## Host -> everyone: the move just applied, its number, and a fingerprint of
## the resulting state so a player catches the instant their mirror drifts.
func _broadcast_applied(_action: Dictionary) -> void:
	var wire := _applied_wire.duplicate() # described before it applied (see _apply_and_animate)
	_action_log.append(wire)
	var sent := wire.duplicate()
	sent["fp"] = _state_fingerprint()
	if _net_trace:
		print("[trace] n=%d %s fp=%d | %s" % [_action_log.size() - 1, wire, sent.fp, _state_debug()])
	Net.broadcast({t = "act", n = _action_log.size() - 1, w = sent})


## Client: numbered moves from the host (one live, or a batch filling a gap).
## Applied strictly in order; a gap asks the host to resend from there.
func _queue_acts(first: int, wires: Array) -> void:
	if first < 0 or game == null or _rebuilding:
		return
	for i in wires.size():
		var n := first + i
		if n >= _action_log.size():
			_incoming_acts[n] = wires[i]
	_drain_incoming_acts()


func _drain_incoming_acts() -> void:
	if _draining_acts or game == null:
		return
	_draining_acts = true
	while true:
		var n := _action_log.size()
		if not _incoming_acts.has(n):
			if not _incoming_acts.is_empty() and _asked_from != n:
				_asked_from = n # missed one: ask for everything from here
				Net.send_to_host({t = "need", from = n})
			break
		while _busy and is_inside_tree():
			await get_tree().process_frame
		if not is_inside_tree():
			return
		var wire: Dictionary = _incoming_acts[n]
		_incoming_acts.erase(n)
		var seat: int = int(wire.get("player", -1))
		var action := _resolve_wire_action(wire, seat)
		if seat == human_seat:
			_awaiting_ack = false
			_pending_wire = {}
		if action.is_empty():
			push_error("[net] DESYNC: can't apply move %d %s | %s" % [n, wire, _state_debug()])
			_bail_desync()
			return
		var clean := wire.duplicate()
		clean.erase("fp")
		_action_log.append(clean)
		await _apply_and_animate(action)
		if n == _test_desync_at and not game.discard.is_empty():
			game.discard.pop_back() # test hook: knock our board out of step on purpose
			_test_desync_at = -1
		if _net_trace:
			print("[trace] n=%d %s fp=%d | %s" % [n, clean, _state_fingerprint(), _state_debug()])
		if wire.has("fp") and int(wire.fp) != _state_fingerprint():
			push_error("[net] DESYNC after move %d %s: host fp=%d mine=%d | %s" % [
				n, wire, int(wire.fp), _state_fingerprint(), _state_debug()])
			_bail_desync()
			return
	_draining_acts = false


## The host is the truth: a player whose board drifted asks for the host's
## whole move log and rebuilds from it (an instant replay) instead of
## leaving. Only if that keeps failing do they go back to the menu.
var _rebuilds := 0
var _rebuilding := false
func _bail_desync() -> void:
	_draining_acts = false
	_incoming_acts.clear()
	_rebuilds += 1
	if _is_authority() or _rebuilds > 3 or not Net.host_reachable():
		_on_disconnected_unexpectedly("Lost sync with the host. Back to the menu.")
		return
	push_warning("[net] out of sync - rebuilding from the host's moves (try %d)" % _rebuilds)
	_rebuilding = true # moves arriving meanwhile are in the rebuild anyway
	_awaiting_ack = false
	_pending_wire = {}
	Net.send_to_host({t = "resync"})


## Who sent this: Steam ID -> seat, or ENet peer -> seat. On LAN a player
## tells us its seat in "ready" (local test only), which also maps a
## reconnecting instance's new peer id.
func _seat_of(key: int, msg: Dictionary = {}) -> int:
	var seat := NetSession.seat_steam_id.find(key) if Net.mode == Net.Mode.STEAM else NetSession.seat_peer_id.find(key)
	if seat < 0 and Net.mode == Net.Mode.LAN and msg.has("seat"):
		seat = int(msg.seat)
		if seat >= 0 and seat < NetSession.seat_peer_id.size():
			NetSession.seat_peer_id[seat] = key
	return seat


## A seat switches between a person and a bot (a drop, a rejoin, the old host
## leaving). The host decides and tells everyone; bots only act on the host.
func _set_seat_bot(seat: int, bot: bool) -> void:
	if seat < 0 or seat >= NetSession.seat_is_bot.size() or seat == human_seat and bot:
		return
	if NetSession.seat_is_bot[seat] == bot:
		return
	NetSession.seat_is_bot[seat] = bot
	var who := NetSession.player_names[seat] if NetSession.player_names[seat] != "" else "P%d" % seat
	var line := "%s left, a bot took their seat" % who if bot else "%s is back" % who
	_flash_effect([line])
	print("[net] seat %d: %s" % [seat, line])
	if game != null:
		_update_seat_label(seat)
	if _is_authority():
		Net.broadcast({t = "seat", seat = seat, bot = bot})
		_turn_epoch += 1
		_run_bot_turns()


## Host: someone left the lobby / dropped. Before the start they're just not
## ready; mid-game a bot takes over so nobody's left waiting on them.
func _on_member_left(key: int) -> void:
	if not _is_authority():
		return
	var seat := _seat_of(key)
	if seat < 0 or seat == human_seat:
		return
	if not _pregame_started:
		_ready_seats.erase(seat)
		_refresh_pregame_rows()
		return
	_set_seat_bot(seat, true)


## Steam handed the lobby to someone else (the host left). Every machine has
## the full game, so play carries on: the new host takes the old host's seat
## over with a bot and lines everyone's move logs up.
func _on_host_changed(new_key: int) -> void:
	var old_seat := _seat_of(_last_host_key)
	_last_host_key = new_key
	if game == null or not Net.is_host():
		if not _pending_wire.is_empty(): # our move went to the old host: resend
			Net.send_to_host({t = "req", w = _pending_wire})
		return
	print("[net] host left - taking over at move %d" % _action_log.size())
	_flash_effect(["The host left. You're hosting now."])
	_draining_acts = false
	_incoming_acts.clear()
	Net.broadcast({t = "host", n = _action_log.size()})
	if old_seat >= 0:
		_set_seat_bot(old_seat, true)
	if not _pending_wire.is_empty(): # our own move never got confirmed: apply it ourselves
		var action := _resolve_wire_action(_pending_wire, human_seat)
		_pending_wire = {}
		_awaiting_ack = false
		if not action.is_empty():
			await _perform(action)
	_run_bot_turns()


## Client, after a host change: catch up with the new host, or hand it the
## moves it missed from the old one.
func _client_on_new_host(_host: int, host_n: int) -> void:
	_asked_from = -1
	if _action_log.size() > host_n:
		Net.send_to_host({t = "extra", from = host_n, log = _action_log.slice(host_n)})
	elif _action_log.size() < host_n:
		Net.send_to_host({t = "need", from = _action_log.size()})


## New host: moves a player saw from the old host that we never got. The old
## host had already validated them, so apply them (numbered, broadcast) as ours.
func _host_on_extra(from: int, wires: Array) -> void:
	for i in wires.size():
		if from + i != _action_log.size():
			continue # already have it (several players can send the same ones)
		while _busy and is_inside_tree():
			await get_tree().process_frame
		if not is_inside_tree():
			return
		var action := _resolve_wire_action(wires[i], int(wires[i].get("player", -1)))
		if action.is_empty():
			push_error("[net] can't take over move %d %s" % [from + i, wires[i]])
			return
		if await _apply_and_animate(action):
			_broadcast_applied(action)


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
		parts.append("%d%s" % [pair.attack.suit * 100 + pair.attack.rank, pair.attack.special])
		parts.append("-" if pair.defense == null else "%d%s" % [pair.defense.suit * 100 + pair.defense.rank, pair.defense.special])
	for hand in game.hands:
		var ranks: Array = []
		for c in hand:
			ranks.append("%d%s" % [c.suit * 100 + c.rank, c.special]) # specials too: same-looking cards can differ
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


## Headless test hook (see _ready()): stands in for a client's missing UI by
## submitting, for OUR seat only, whatever a bot would have played - through
## the exact same _perform()/RPC path a real drag-and-drop uses.
func _run_client_autoplay() -> void:
	var quit_after := -1
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--desync-at="):
			_test_desync_at = int(str(a).get_slice("=", 1))
		if str(a).begins_with("--lan-quit-after="):
			quit_after = int(str(a).get_slice("=", 1))
	var moves := 0
	while game == null:
		await _wait(0.05) # a guest's board only exists once the host lets it in
	var run_id := _game_id
	while game != null and not game.is_finished():
		if run_id != _game_id:
			return
		if _busy or _awaiting_ack or _draining_acts or not _incoming_acts.is_empty():
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
		moves += 1
		if moves == quit_after:
			print("[lan] seat %d walking out after %d moves" % [human_seat, moves])
			get_tree().quit()
			return
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
		if action.card.special != &"":
			wire.sp = str(action.card.special) # draft offers can share suit + rank, differing only in this
		# Which copy: Forge / Propaganda can leave two cards with the same suit
		# and rank in one hand, and picking the wrong one desyncs later (the
		# bout-end revert restores the other card). Every peer's hand is in
		# the same order, so the position pins it down.
		var at: int = game.hands[action.player].find(action.card) if action.player >= 0 else -1
		if at >= 0:
			wire.hi = at
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
		if wants_card and str(candidate.card.special) != str(wire.get("sp", "")):
			continue # same suit + rank, different special (two draft offers alike)
		if wire.has("hi") and game.hands[seat].find(candidate.card) != int(wire.hi):
			continue # the other copy of a forged card
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
## Returns false if the move was no longer legal by its turn (and so wasn't applied).
func _apply_and_animate(action: Dictionary) -> bool:
	while _busy and is_inside_tree():
		await get_tree().process_frame
	# Two callers can pick a move in the same frame (the bot loop, your own
	# drop, a network request): the one that waited above may have been made
	# stale by the one that went first. Applying it anyway put the host in a
	# state nobody else reached - a desync. So: still legal, or dropped.
	if game == null or not _still_legal(action):
		return false
	var run_id := _game_id
	_busy = true
	_busy_since = Time.get_ticks_msec() / 1000.0
	_waiting_for_human = false
	var before := _snapshot()
	# Where the played card would sit - computed now, because a card that ends
	# the bout in the same action (the Joker) is already off the table after.
	var lead: CardData = action.get("card") if action.type in ["attack", "defend", "deflect"] else null
	var lead_slot := {}
	if lead != null:
		var n := game.table.size()
		var defending: bool = action.type == "defend"
		var j := _table_jitter(lead)
		var i: int = action.target if defending else n
		var count := n if defending else n + 1
		lead_slot = {pos = _table_slot_pos(i, count, defending) + Vector2(j.x, j.y),
			angle = (0.14 if defending else 0.0) + j.z, z = _table_z(i, defending)}

	# The move as the network describes it - taken now, before applying, while
	# the card is still in hand and still has its special (Sift clears its own
	# on pickup, a played card has left the hand): describing it afterwards
	# matched the wrong copy on the other machines.
	_applied_wire = _action_to_wire(action)
	game.apply_action(action)
	# Cards that just left my hand (played, discarded by a special) stop being
	# hand cards right now - not at the end-of-move resync. Otherwise once a
	# played card's flight finished, the hand loop pulled it back into the fan
	# for the rest of the move (most visible while CLEARED holds the table).
	if human_seat >= 0:
		var still_held: Array = game.hands[human_seat]
		_hand_slots = _hand_slots.filter(func(sl): return sl.card in still_held)
	# Captured immediately - apply_action() clears effect_log at its own next
	# call, and a bot's next move could come before this one finishes animating.
	if not game.effect_log.is_empty():
		_flash_effect(game.effect_log.duplicate())
	# Mirror's peeks (spec 5, Sleight) are seat-scoped, not a table-wide toast -
	# only show the ones meant for this client's own seat.
	_show_peeks(game.private_log)

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
	# The played card went hand -> table -> gone in one action (the Joker ends
	# the attack on the spot): still show it landing before the table clears.
	if lead != null and before.get(lead, "").begins_with("hand:") and lead not in played \
			and lead not in burned_now.map(func(e): return e.card):
		special_moved = special_moved.filter(func(e): return e.card != lead)
		played.append(lead)
		var now: String = after.get(lead, "")
		if now == "discard":
			discarded.append(lead)
		elif now.begins_with("hand:"):
			taken.append(lead)
			taker = now.substr(5).to_int()

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
		if card == lead and not game.table.any(func(p): return p.attack == card or p.defense == card):
			slot = lead_slot
		view.z_index = slot.z
		_animate_to(view, slot.pos, slot.angle, _fit_scale(view, table_card_height), play_anim, 0.0)
	if not played.is_empty():
		Sfx.deal_burst(played.size(), deal_stagger)
		await _wait(play_beat)
		if run_id != _game_id: return true

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
		if run_id != _game_id: return true

	# 1.5 burned cards go up in flames where they are, before the table clears
	if not burned_now.is_empty():
		Sfx.fire()
		for entry in burned_now:
			_animate_burn(entry.card, entry.from)
		await _wait(burn_beat)
		if run_id != _game_id: return true

	# 2. clear the table
	if not discarded.is_empty():
		# the bout is over: stamp it, let it sink in, then sweep. The old
		# prompt ("YOUR MOVE · DEFEND", Take/Pass) goes now - the end-of-move
		# resync brings back whatever the next bout needs
		for hud in [_turn_banner, _take_button, _pass_button, _confirm_button, _deflect_strip]:
			hud.visible = false
		var stamp := _stamp_table("CLEARED")
		await _wait(stamp_beat)
		if run_id != _game_id: return true
		if is_instance_valid(stamp):
			stamp.create_tween().tween_property(stamp, "modulate:a", 0.0, clear_anim).finished.connect(stamp.queue_free)
		Sfx.fan()
		await _wait(_sweep_to_discard(discarded))
		if run_id != _game_id: return true
		_sync_back_stack(_discard_stack, mini(game.discard.size(), 5),
			discard_pos, discard_card_height, 1)
		await _wait(clear_beat)
		if run_id != _game_id: return true
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
		if run_id != _game_id: return true

	# 2.5. special effects visibly relocate a card - Sift, Cull, and future ones
	if not special_moved.is_empty():
		for entry in special_moved:
			_animate_special_move(entry.card, entry.from, entry.to)
		await _wait(special_move_beat)
		if run_id != _game_id: return true

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
			if run_id != _game_id: return true

	_busy = false
	if run_id != _game_id:
		return true
	_resync() # 4. settle every sprite to the final layout and unlock input
	return true


## A passport-style ink stamp slammed over the middle of the table, tilted
## like it was done by hand. Caller frees it.


func _stamp_table(text: String) -> Control:
	var box := _special_ui.ink_box(text, 92, 7)
	box.z_index = 900 # over every table card
	_ephemeral_views[box] = true # not a card: keep the orphan sweep off it
	box.tree_exiting.connect(func(): _ephemeral_views.erase(box))
	_card_layer.add_child(box)
	_special_ui.slam(box)
	box.position = BOARD_CENTER - box.pivot_offset
	box.rotation = randf_range(-0.22, -0.1)
	return box


## Is this exact move (same type, player, card, target) still on offer?
func _still_legal(action: Dictionary) -> bool:
	for candidate in game.get_legal_actions(int(action.get("player", -1))):
		if candidate.type == action.type and candidate.get("card") == action.get("card") 				and candidate.get("target", -1) == action.get("target", -1):
			return true
	return false


func _wait(seconds: float) -> void:
	if not is_inside_tree():
		return # the board is gone (back to the menu): let the caller's run_id check bail
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
			var targets := _choice_target_seats()
			for seat in targets:
				if _seat_click_rect(seat).has_point(_mouse()):
					_submit(targets[seat])
					return
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
			_special_ui.close_dossier()
			return


func _end_drag() -> void:
	if _drag.is_empty() or _drag.get("dropped", false):
		return
	var mouse := _mouse()
	# Let go while a bot's card is still landing (they throw in while you
	# defend): _submit() would refuse it and leave the card stranded on the
	# table with the game waiting on you. Hold it where it was dropped and
	# play it once the board settles - or send it home if that made it illegal.
	if _busy or _awaiting_ack:
		_drag.dropped = true
		var held: Dictionary = _drag
		while (_busy or _awaiting_ack) and is_same(_drag, held):
			await get_tree().process_frame
		if not is_same(_drag, held):
			return # a restart / resync dropped it meanwhile
	if game.phase == DurakGame.Phase.SPECIAL_CHOICE:
		var picks := _special_choice_actions().filter(func(a): return a.get("card") == _drag.card)
		var picked: Node2D = _drag.view
		_drag = {}
		if is_instance_valid(picked):
			picked.z_index = 0
		if picks.size() == 1:
			_submit(picks[0])
		elif picks.size() > 1: # Forge source: rank or suit?
			_forge_pick = picks[0].card
			_rebuild_forge_modes()
		return
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
						_hold_dropped()
						_submit(action)
						return

	# 2. defender, free table space (or the ghost "pass" slot) -> pass the
	# attack on. Table cards are masked: a drop on/near one that couldn't
	# beat it (step 1) just goes home instead of being read as a pass.
	var on_pass_slot := _deflect_strip.visible and _deflect_strip.get_global_rect().has_point(mouse)
	if on_pass_slot or (table_drop_rect.has_point(mouse) and not _over_table_card(mouse)):
		for action in actions:
			if action.type == "deflect" and action.card == _drag.card:
				_hold_dropped()
				_submit(action)
				return

	# 3. attackers: anywhere on the table -> attack / throw in
	if table_drop_rect.has_point(mouse):
		for action in actions:
			if action.type == "attack" and action.card == _drag.card:
				_hold_dropped()
				_play_local(action)
				return

	# 4. no valid target -> let _process glide the card home
	var view: Node2D = _drag.view
	_drag = {}
	if is_instance_valid(view):
		view.z_index = 0


## A played card stays where it was let go until the move lands. On a
## multiplayer client the move goes to the host first; without this the hand
## pulled the card back into the fan while waiting, then the host's answer
## flew it out again - a rubber band. Cleared by the next resync (the move
## applied, or the host refused it and the card goes home).
func _hold_dropped() -> void:
	if is_instance_valid(_drag.view):
		_drag.view.set_meta("held", true)


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


## Mirror's peeks. Mine from this one action merge into a single open dossier
## (Solidarity can fire several at once); anyone else's show as a sealed
## folder over each player they looked at, so you know it happened, not what.
func _show_peeks(entries: Array) -> void:
	var mine: Array = []
	var single_target := true
	var first_target := -2
	for entry in entries:
		if not entry.has("picks"):
			continue
		if entry.seat == human_seat:
			mine.append_array(entry.picks)
			if first_target == -2:
				first_target = entry.target
			single_target = single_target and entry.target >= 0 and entry.target == first_target
			_effect_history_add("[peek] " + _pretty(entry.text))
		else:
			var targets := {}
			for pick in entry.picks:
				targets[pick.owner] = true
			for target in targets:
				_special_ui.sealed(target, entry.seat)
	if mine.is_empty():
		return
	var title := "Mirror: one card from each player"
	var about := -1
	if single_target:
		about = first_target
		title = "Mirror: %s's cards" % _display_name(first_target)
	_special_ui.peek(title, mine, about)


## Queues the special-card catalogue's effect log to show over the table, one
## message at a time, and keeps it in the Log so a missed one isn't lost.
func _flash_effect(messages: Array[String]) -> void:
	for msg in messages:
		var text := _pretty(msg)
		_effect_queue.append(text)
		_effect_history_add(text)


## Engine log line -> something a person reads: seat numbers become names,
## "6C" becomes "6♣", and "You" gets its grammar ("You draft ... your").
var _card_token := RegEx.create_from_string("\\b(10|[2-9JQKA]|Jk)([CDHS])\\b")
func _pretty(text: String) -> String:
	var t := _localize_seat_names(text)
	var found := _card_token.search_all(t)
	found.reverse() # replace back to front so earlier offsets stay valid
	for m in found:
		var suit := "CDHS".find(m.get_string(2))
		var rank := "Joker" if m.get_string(1) == "Jk" else m.get_string(1)
		t = t.substr(0, m.get_start()) + rank + SUIT_GLYPHS[suit] + t.substr(m.get_end())
	if t.begins_with("You drafts"):
		t = t.replace("You drafts", "You draft").replace("their reserve", "your reserve")
	t = t.replace("You's", "your").replace(" You ", " you ").replace(" You.", " you.")
	if t.ends_with(" You"):
		t = t.left(-3) + "you"
	return t


# ---------------------------------------------------------------- effect log

## The last few things specials did, behind a "Log" button by the menu one.
const LOG_LINES := 12
var _effect_history: Array[String] = []
var _log_panel: PanelContainer
var _log_list: VBoxContainer


func _build_log() -> void:
	var button: Button = _pause_button.duplicate()
	button.text = "Log"
	button.offset_left = _pause_button.offset_left - 108.0
	button.offset_right = _pause_button.offset_left - 12.0
	_ui_root.add_child(button)
	button.pressed.connect(func(): _log_panel.visible = not _log_panel.visible)
	_log_panel = PanelContainer.new()
	_log_panel.theme_type_variation = &"PlatePanel"
	_log_panel.visible = false
	_log_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_log_panel.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			_log_panel.visible = false)
	_log_list = VBoxContainer.new()
	_log_panel.add_child(_log_list)
	_ui_root.add_child(_log_panel)
	_refresh_log()


func _effect_history_add(text: String) -> void:
	_effect_history.append(text)
	if _effect_history.size() > LOG_LINES:
		_effect_history.pop_front()
	_refresh_log()


func _refresh_log() -> void:
	if _log_list == null:
		return
	for child in _log_list.get_children():
		_log_list.remove_child(child)
		child.queue_free()
	var lines := _effect_history.duplicate()
	lines.reverse() # newest on top
	if lines.is_empty():
		lines = ["Nothing yet. Special card effects show up here."]
	for i in lines.size():
		var label := Label.new()
		label.theme_type_variation = &"HudLabel"
		label.add_theme_font_size_override("font_size", 22)
		label.text = lines[i]
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size.x = 560
		label.modulate.a = 1.0 if i == 0 else 0.75
		_log_list.add_child(label)
	_log_panel.reset_size()
	_log_panel.position = Vector2(1920.0 - 40.0 - _log_panel.size.x, 90.0)


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


## A special's choice (Palm/Singleout/Denunciation: click a player; Stack:
## the overlay; Forge: click hand cards) pauses the whole table, so a timer
## still auto-picks at random if it's left untouched - shown on the banner.
func _update_special_choice_timer() -> void:
	var choices := _special_choice_actions()
	if special_choice_seconds <= 0.0 or _busy or _menu_open or _awaiting_ack or choices.is_empty():
		_special_choice_deadline = -1.0
		return
	var now := Time.get_ticks_msec() / 1000.0
	if _special_choice_deadline < 0.0:
		_special_choice_deadline = now + special_choice_seconds
	var remaining := _special_choice_deadline - now
	var shown := "%s   %d" % [_choice_banner(), ceili(maxf(remaining, 0.0))]
	if _choice_kind() == "stack":
		_turn_banner.visible = false # the overlay's title says it
	elif _turn_banner.text != shown:
		_turn_banner.text = shown
		_turn_banner.reset_size()
		_turn_banner.position.x = 960.0 - _turn_banner.size.x * 0.5
	if _draft_overlay.visible and _draft_pick_actions().is_empty():
		_draft_countdown.text = "auto-picks in %d..." % ceili(maxf(remaining, 0.0)) # Stack
	_countdown_tick("special", remaining)
	if remaining <= 0.0:
		_special_choice_deadline = -1.0
		_forge_pick = null
		_submit(choices[randi() % choices.size()])


## The pending choice's kind ("palm", "stack", "forge_source"...) when it's
## this player's to make, else "".
func _choice_kind() -> String:
	if game == null or game.phase != DurakGame.Phase.SPECIAL_CHOICE or _special_choice_actions().is_empty():
		return ""
	return game._special_choice.get("kind", "")


func _choice_banner() -> String:
	match _choice_kind():
		"palm": return "PALM  ·  PICK WHO TO SWAP WITH"
		"singleout": return "SINGLEOUT  ·  PICK WHO DEFENDS"
		"denounce": return "DENUNCIATION  ·  PICK WHO DEFENDS NEXT"
		"stack": return "STACK  ·  SET THE TALON'S ORDER"
		"forge_target": return "FORGE  ·  PICK A CARD TO CHANGE"
		"forge_source": return "FORGE  ·  PICK A CARD TO COPY FROM"
	return "YOUR MOVE  ·  CHOOSE"


## Seats the pending choice lets you click (Palm/Singleout/Denunciation).
func _choice_target_seats() -> Dictionary:
	var seats := {}
	if _choice_kind() in ["palm", "singleout", "denounce"]:
		for action in _special_choice_actions():
			seats[action.target] = action
	return seats


## Where a click counts as picking `seat`: its plate, or its fan of cards.
func _seat_click_rect(seat: int) -> Rect2:
	var plate: Control = _seat_labels[seat]
	var rect := Rect2(plate.position, plate.get_combined_minimum_size()).grow(8.0)
	var fan := Rect2(_seat_layout(seat).origin - Vector2(130, 130), Vector2(260, 260))
	return rect.merge(fan)


## Forge's second step: a card copyable both ways (rank and suit) asks which,
## with two buttons over your hand. `_forge_pick` = the source card clicked.
var _forge_pick: CardData = null
var _forge_modes: HBoxContainer = null
func _rebuild_forge_modes() -> void:
	if _forge_modes != null:
		_forge_modes.queue_free()
		_forge_modes = null
	if _choice_kind() != "forge_source" or _forge_pick == null:
		_forge_pick = null
		return
	var target: CardData = game._special_choice.get("target")
	_forge_modes = HBoxContainer.new()
	_forge_modes.add_theme_constant_override("separation", 16)
	for action in _special_choice_actions():
		if action.card != _forge_pick:
			continue
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		var rank_name: String = CardData.RANK_NAMES.get(_forge_pick.rank, str(_forge_pick.rank))
		b.text = "Copy rank (%s)" % rank_name if action.target == 0 else "Copy suit (%s)" % SUIT_GLYPHS[_forge_pick.suit]
		b.pressed.connect(func():
			_forge_pick = null
			_submit(action))
		_forge_modes.add_child(b)
	var hint := Label.new()
	hint.theme_type_variation = &"Toast"
	hint.text = "onto your %s" % _pretty(str(target)) if target != null else ""
	_forge_modes.add_child(hint)
	_ui_root.add_child(_forge_modes)
	_forge_modes.size = _forge_modes.get_combined_minimum_size()
	_forge_modes.position = Vector2(960.0 - _forge_modes.size.x * 0.5, 740.0)


func _process(_delta: float) -> void:
	if _busy and Time.get_ticks_msec() / 1000.0 - _busy_since > BUSY_WATCHDOG:
		push_error("[game] a move animation never finished - unsticking the board | %s" % _state_debug())
		_busy = false
		_resync()
		if _is_authority():
			_run_bot_turns()
	_update_effect_toast()
	_update_card_tooltip()
	_update_throw_in_timer()
	_update_draft_timer()
	_update_special_choice_timer()
	_update_draft_hover()
	var pulse := 1.0 + 0.25 * (0.5 + 0.5 * sin(Time.get_ticks_msec() / 160.0))
	var targets := _choice_target_seats()
	for seat in _seat_labels.size():
		_seat_labels[seat].modulate = Color(pulse, pulse, pulse) if targets.has(seat) and not _busy else Color.WHITE

	if _hand_slots.is_empty():
		return

	var mouse := _mouse()
	var dragging: bool = not _drag.is_empty()

	if dragging and is_instance_valid(_drag.view) and not _drag.get("dropped", false):
		var dragged: Node2D = _drag.view
		dragged.global_position = dragged.global_position.lerp(
			mouse - _drag.grab_offset, drag_follow)
		if dragged.has_method("set_hover_tilt"):
			dragged.set_hover_tilt(0.0, 0.0) # flatten out as it lifts off the fan
			dragged.set_lifted(true, drag_follow)
		dragged.z_index = 100

	# Hover works the whole game, not just on your move or between animations
	# (with more players, bots moving / bouts you're not in are most of the
	# game, so gating on those made hover feel random). While a move animates,
	# cards it's moving have a "tween" meta and are skipped below.
	var interactive: bool = not dragging and not _awaiting_ack and not _board_blocked() \
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
				# (mid-animation a slot can point at a view that was just freed)
				if is_instance_valid(_hand_slots[i].view) and _hand_slot_rect(_hand_slots[i]).has_point(mouse):
					_hovered_view = _hand_slots[i].view
					break

	if _hovered_view != null and _hovered_view != prev_for_sound \
			and _hand_slots.any(func(sl): return sl.view == _hovered_view and _lifts(sl)):
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
		if view.has_meta("tween") and is_instance_valid(view.get_meta("tween")) and view.get_meta("tween").is_running():
			continue # mid-animation (drawn, played, sorted): the tween owns it
		if view.has_meta("held"):
			continue # dropped on the table, waiting for the move to land
		var raised: bool = view == _hovered_view and _lifts(slot)
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


## Whether a hovered hand card lifts: on your move only the playable ones do
## (a dead card just shows its "why not" tooltip); otherwise any card does, so
## you can look over your hand while the others play.
func _lifts(slot: Dictionary) -> bool:
	return slot.playable or not _waiting_for_human


const PLAYABLE_RISE := 16.0 ## px a playable hand card sits above the rest during your move


## Why `card` (in my hand) can't be played right now - shown as a tooltip on
## hover. Mirrors durak_game's legality checks; "" when it's simply not my move.
func _unplayable_reason(card: CardData) -> String:
	if not _waiting_for_human or human_seat < 0 or game.phase == DurakGame.Phase.SPECIAL_CHOICE:
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
	if game == null:
		return result # a message before the board exists (a seat change while still loading)
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


## Opponents' fans are bunched tight (you only see backs) to leave the table
## room: 16px a card, and a big pickup squeezes to OPP_FAN_MAX_SPAN overall.
const OPP_FAN_STEP := 16.0
const OPP_FAN_MAX_SPAN := 170.0
func _opp_spacing(hand_size: int) -> float:
	return minf(OPP_FAN_STEP, OPP_FAN_MAX_SPAN / maxf(hand_size - 1, 1)) * _opp_scale()


func _opponent_slot_pos(seat: int, index: int, hand_size: int) -> Vector2:
	var layout := _seat_layout(seat)
	var spacing := _opp_spacing(hand_size)
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
	_special_ui.refresh()
	if not _special_choice_actions().is_empty():
		_special_ui.close_dossier() # its cards stay as chips; it mustn't cover the choice
	_rebuild_forge_modes()

	# _process drives the hand every frame (fan pose + hover); drop the settle
	# tween so the two don't fight over the same transform
	for slot in _hand_slots:
		_stop_tween(slot.view)


## Everything a face-up card's look depends on beyond suit/rank - applied the
## moment a view exists, so a card in flight already looks like it will once it
## lands (no shimmer/status/glaze "pop" on arrival).
func _dress(view: Sprite2D, card: CardData) -> void:
	var suit_name: String = CardData.SUIT_NAMES[card.suit]
	if view.face_up and (view.suit != suit_name or view.rank != card.rank):
		view.setup(suit_name, card.rank, true) # Forge / Propaganda re-inked it
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


## A beaten table goes the way a person clears it: a hand sweeps the cards
## into one rough pile on the discard side (left cards first, the way the
## hand travels), each card tips up on its edge and comes down face-down,
## then the pile slides onto the discard. Returns how long it all takes.
func _sweep_to_discard(cards: Array[CardData]) -> float:
	var gather := Vector2(discard_pos.x - 320.0, BOARD_CENTER.y)
	var sweep := clear_anim * 0.8
	var edge := 0.09
	var views: Array[Sprite2D] = []
	for card in cards:
		var view: Sprite2D = _card_views.get(card)
		if view != null:
			_card_views.erase(card)
			views.append(view)
	if views.is_empty():
		return 0.0
	var min_x: float = views.map(func(v): return v.position.x).min()
	var max_delay := 0.0
	for i in views.size():
		var view := views[i]
		_ephemeral_views[view] = true # exempt from the orphan sweep while it flies
		_stop_tween(view)
		if view.has_method("set_hover_tilt"):
			view.set_hover_tilt(0.0, 0.0)
		var delay := (view.position.x - min_x) / 1400.0 * 0.3
		max_delay = maxf(max_delay, delay)
		var full_x := view.scale.x
		var t := view.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		t.tween_interval(delay)
		t.tween_property(view, "position", gather + Vector2(i * 3.0, -i * 2.0), sweep)
		t.parallel().tween_property(view, "rotation", randf_range(-0.08, 0.08), sweep)
		t.tween_property(view, "scale:x", 0.0, edge).set_ease(Tween.EASE_IN) # up on its edge
		t.tween_callback(func():
			var back := _new_back(view.position, view.z_index)
			back.rotation = view.rotation
			back.scale = Vector2(0.0, view.scale.y)
			_ephemeral_views[back] = true
			_ephemeral_views.erase(view)
			view.queue_free()
			var bt := back.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			bt.tween_property(back, "scale:x", full_x, edge) # ...and down, face-down
			var land := _fit_scale(back, discard_card_height)
			bt.tween_property(back, "position", discard_pos, clear_anim)
			bt.parallel().tween_property(back, "rotation", 0.0, clear_anim)
			bt.parallel().tween_property(back, "scale", land, clear_anim)
			bt.tween_callback(func():
				_ephemeral_views.erase(back)
				back.queue_free()))
	return max_delay + sweep + edge * 2.0 + clear_anim


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
		# face-down into someone else's hand (Holdout, Palm, Requisition): a
		# back makes the trip so it doesn't just appear in their fan
		var back := _new_back(_zone_pos(from_zone), 30)
		back.scale = _fit_scale(back, talon_card_height)
		_ephemeral_views[back] = true
		var trip := back.create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		trip.tween_property(back, "position", _zone_pos(to_zone), special_move_anim)
		trip.tween_property(back, "modulate:a", 0.0, 0.15)
		trip.tween_callback(func():
			_ephemeral_views.erase(back)
			back.queue_free())
		return

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
	if _choice_target_seats().has(seat):
		label.text += "   ◂ PICK"
		plate = &"SeatPlateAttack"
	label.theme_type_variation = plate
	label.visible = true
	label.reset_size()
	var size := label.get_combined_minimum_size()

	if seat == _near_seat():
		label.position = Vector2(24, 860)
		return
	var card_h := opponent_card_height * _opp_scale()
	var card_w := card_h * 500.0 / 726.0
	var span := _opp_spacing(game.hands[seat].size()) * maxf(game.hands[seat].size() - 1, 0)
	if layout.vertical: # side fan runs down, cards sideways: plate above its top end
		label.position = layout.origin + Vector2(-size.x * 0.5, -span * 0.5 - card_w * 0.5 - 12.0 - size.y)
	else: # top fan runs across: plate just below it
		label.position = layout.origin + Vector2(-size.x * 0.5, card_h * 0.5 + 10.0)
	label.position.x = clampf(label.position.x, 12.0, 1908.0 - size.x)


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
	if not _awaiting_ack: # our move landed (or was refused): nothing stays held
		for held_view in _card_views.values():
			if is_instance_valid(held_view) and held_view.has_meta("held"):
				held_view.remove_meta("held")
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
				text = "" if _choice_kind() == "stack" else _choice_banner()
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
	if _choice_kind() == "stack":
		# same overlay: the talon's top cards face-up, click them in the order
		# you want to draw them; the ones already placed sit below, numbered
		draft_actions = _special_choice_actions()
		var placed: Array = game._special_choice.get("order", [])
		_draft_overlay.visible = true
		_draft_title.text = "Stack: pick the %s card off the talon" % _ordinal(placed.size() + 1)
		_rebuild_draft_cards(draft_actions, placed)
		return
	_rebuild_draft_cards(draft_actions)


## Rebuilds the draft overlay's offered cards from scratch every call (there
## are never more than 4, so this is cheap): a real card sprite per offer, for
## the tooltip hover and the name band, plus an invisible click target the
## same size laid on top of it, since Sprite2D has no click signal of its own.
func _rebuild_draft_cards(actions: Array, placed: Array = []) -> void:
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

	# Stack's already-ordered cards, small, numbered by when they'll be drawn
	for i in placed.size():
		var card: CardData = placed[i]
		var view := _instance_card()
		view.setup(CardData.SUIT_NAMES[card.suit], card.rank, true)
		_dress(view, card)
		view.scale = Vector2.ONE * (130.0 / maxf(view.texture.get_height(), 1.0))
		view.position = Vector2(960.0 - (placed.size() - 1) * 55.0 + i * 110.0, 900)
		view.set_meta("home_pos", view.position)
		view.set_meta("home_scale", view.scale)
		_draft_overlay.add_child(view)
		_draft_card_views[card] = view
		var num := Label.new()
		num.theme_type_variation = &"Toast"
		num.text = _ordinal(i + 1)
		num.position = view.position + Vector2(-30, -110)
		_draft_overlay.add_child(num)
		_draft_buttons.append(num) # freed with the rest on the next rebuild





func _unbeaten_count() -> int:
	var count := 0
	for pair in game.table:
		if pair.defense == null:
			count += 1
	return count
