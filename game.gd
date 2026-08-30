extends Node2D
## The playable board. Seat `human_seat` is the user (Slay-the-Spire style drag);
## the other seats are driven by Bot. Rendering is identity-based: every card owns
## one persistent Sprite2D kept in `_card_views` (keyed by its CardData). On each
## rules change the views tween to their new positions, so pickups, refills and
## finished bouts stay followable. Hidden zones (opponent hands, the talon body,
## the discard pile) are drawn as pools of face-down "back" sprites.

const CARD_SCENE := preload("res://card.tscn")
const SUIT_GLYPHS := ["♣", "♦", "♥", "♠"]
const BOARD_CENTER := Vector2(960, 540)

@export var human_seat := 0 ## -1 = watch mode (every seat is a bot)

@export_group("Pacing (seconds)")
@export_range(0.0, 3.0, 0.05) var bot_delay := 0.7  ## pause before each bot move; the board stays live during it
@export_range(0.0, 1.5, 0.01) var move_duration := 0.34 ## generic settle tween
@export_range(0.0, 1.5, 0.01) var play_anim := 0.30    ## played card sliding onto the table
@export_range(0.0, 1.5, 0.01) var play_beat := 0.34    ## hold after a card is played
@export_range(0.0, 1.5, 0.01) var clear_anim := 0.46   ## cards leaving the table (to discard / into a hand)
@export_range(0.0, 1.5, 0.01) var clear_beat := 0.58   ## hold after the table clears
@export_range(0.0, 1.5, 0.01) var refill_anim := 0.28  ## a card flying from the talon into a hand
@export_range(0.0, 1.5, 0.01) var refill_beat := 0.24  ## hold after each seat refills

@export_group("Card feel")
@export_range(0.0, 120.0, 1.0) var hover_raise := 46.0 ## px a hovered hand card lifts
@export_range(1.0, 1.6, 0.01) var hover_scale := 1.12  ## size multiplier while hovered
@export_range(0.05, 1.0, 0.01) var hand_follow := 0.30 ## how fast hand cards ease to their slot
@export_range(0.05, 1.0, 0.01) var drag_follow := 0.40 ## how fast a dragged card chases the cursor

@export_group("Card sizes (px tall)")
@export_range(40.0, 320.0, 1.0) var hand_card_height := 200.0
@export_range(40.0, 320.0, 1.0) var table_card_height := 140.0
@export_range(40.0, 320.0, 1.0) var talon_card_height := 140.0
@export_range(40.0, 320.0, 1.0) var opponent_card_height := 118.0
@export_range(40.0, 320.0, 1.0) var discard_card_height := 130.0

@export_group("Positions")
@export var talon_pos := Vector2(250, 560)
@export var discard_pos := Vector2(1690, 560)
@export var table_drop_rect := Rect2(500, 350, 920, 380) ## where a dragged card counts as "on the table"
@export var translate_strip_rect := Rect2(660, 232, 600, 96) ## the "pass the attack on" drop strip

var game: DurakGame

# --- persistent scene nodes ----------------------------------------------------
var _slot_layer: Node2D          # empty-pile outline markers, drawn behind the cards
var _talon_marker: Line2D
var _discard_marker: Line2D
var _card_layer: Node2D          # every card / back sprite lives here
var _ui_layer: CanvasLayer
var _status_label: Label         # top line: trump / phase / pile counts
var _take_button: Button
var _pass_button: Button
var _translate_strip: ColorRect  # "drop here to pass the attack on"
var _talon_label: Label
var _discard_label: Label
var _seat_labels: Array[Label] = []
var _end_screen: ColorRect
var _end_title: Label
var _end_standings: Label

# --- view bookkeeping --------------------------------------------------------
var _card_views: Dictionary = {}      # CardData   -> Sprite2D (one per face-up card)
var _opponent_backs: Dictionary = {}  # seat (int) -> Array[Sprite2D]
var _talon_stack: Array[Sprite2D] = []
var _discard_stack: Array[Sprite2D] = []

# --- frame state ------------------------------------------------------------
var _game_id := 0                 # bumped per game; a stale coroutine bails on mismatch
var _turn_epoch := 0             # bumped when the human acts; the bot loop bails on mismatch
var _busy := false                # an _apply_and_animate() is mid-flight
var _waiting_for_human := false   # the human has at least one legal move right now
var _hand_slots: Array = []       # [{view, card, home_pos, home_scale, playable}]
var _open_attack_views: Array = [] # [{view, table_index}] for not-yet-beaten attacks
var _drag := {}                   # {view, card, home_pos, grab_offset} while dragging
var _hovered_view: Node = null
var _headless := false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	if _headless:
		bot_delay = 0.0
		human_seat = -1 # let the headless smoke test self-play

	_slot_layer = Node2D.new()
	add_child(_slot_layer) # added first -> drawn behind the cards
	_talon_marker = _make_slot_marker(talon_card_height)
	_discard_marker = _make_slot_marker(discard_card_height)
	_card_layer = Node2D.new()
	add_child(_card_layer)
	_ui_layer = CanvasLayer.new()
	add_child(_ui_layer)

	_status_label = _make_label(Vector2(24, 18), 22)
	_talon_label = _make_caption()
	_discard_label = _make_caption()
	_talon_label.text = "Talon"
	_discard_label.text = "Discard"
	_place_slots()
	for _i in 4:
		_seat_labels.append(_make_label(Vector2.ZERO, 18))

	_take_button = _make_button("Take", Vector2(1520, 690), _on_take)
	_pass_button = _make_button("Pass", Vector2(1520, 770), _on_pass)

	_translate_strip = ColorRect.new()
	_translate_strip.color = Color(0.9, 0.75, 0.2, 0.22)
	_translate_strip.position = translate_strip_rect.position
	_translate_strip.size = translate_strip_rect.size
	_translate_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_translate_strip.visible = false
	var strip_label := Label.new()
	strip_label.text = "▲  drop here — pass the attack on"
	strip_label.size = translate_strip_rect.size
	strip_label.add_theme_font_size_override("font_size", 20)
	strip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	strip_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	strip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_translate_strip.add_child(strip_label)
	_ui_layer.add_child(_translate_strip)

	_build_end_screen()

	RenderingServer.set_default_clear_color(Color(0.05, 0.22, 0.12))
	_new_game()


func _make_label(pos: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.position = pos
	label.add_theme_font_size_override("font_size", font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(label)
	return label


# a card-footprint outline that marks a pile spot even when it is empty
func _make_slot_marker(card_height: float) -> Line2D:
	var w := card_height * (500.0 / 726.0)
	var half := Vector2(w, card_height) * 0.5
	var line := Line2D.new()
	line.points = PackedVector2Array([
		-half, Vector2(half.x, -half.y), half, Vector2(-half.x, half.y),
	])
	line.closed = true
	line.width = 2.0
	line.default_color = Color(1.0, 1.0, 1.0, 0.16)
	line.antialiased = true
	_slot_layer.add_child(line)
	return line


# centred caption under a pile ("Talon", "Discard 12", ...)
func _make_caption() -> Label:
	var label := _make_label(Vector2.ZERO, 18)
	label.size.x = 220
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.5))
	return label


func _place_slots() -> void:
	_talon_marker.position = talon_pos
	_discard_marker.position = discard_pos
	_talon_label.position = talon_pos \
		+ Vector2(-_talon_label.size.x * 0.5, talon_card_height * 0.5 + 8.0)
	_discard_label.position = discard_pos \
		+ Vector2(-_discard_label.size.x * 0.5, discard_card_height * 0.5 + 8.0)


func _make_button(text: String, pos: Vector2, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.position = pos
	button.size = Vector2(150, 60)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 22)
	button.pressed.connect(on_pressed)
	button.visible = false
	_ui_layer.add_child(button)
	return button


func _build_end_screen() -> void:
	_end_screen = ColorRect.new()
	_end_screen.color = Color(0.03, 0.05, 0.04, 0.78)
	_end_screen.position = Vector2.ZERO
	_end_screen.size = Vector2(1920, 1080)
	_end_screen.visible = false
	_ui_layer.add_child(_end_screen)

	_end_title = Label.new()
	_end_title.position = Vector2(0, 300)
	_end_title.size = Vector2(1920, 80)
	_end_title.add_theme_font_size_override("font_size", 56)
	_end_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_screen.add_child(_end_title)

	_end_standings = Label.new()
	_end_standings.position = Vector2(0, 430)
	_end_standings.size = Vector2(1920, 220)
	_end_standings.add_theme_font_size_override("font_size", 28)
	_end_standings.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_end_screen.add_child(_end_standings)

	var again_button := Button.new()
	again_button.text = "Play again  (Space)"
	again_button.add_theme_font_size_override("font_size", 26)
	again_button.size = Vector2(320, 72)
	again_button.position = Vector2(BOARD_CENTER.x - 160, 700)
	again_button.focus_mode = Control.FOCUS_NONE
	again_button.pressed.connect(_restart)
	_end_screen.add_child(again_button)


# ---------------------------------------------------------------- game lifecycle

func _new_game() -> void:
	_game_id += 1
	_turn_epoch += 1
	_busy = false
	game = DurakGame.new(4, 0)
	game.game_over.connect(_on_game_over)
	_resync() # deal: every view spawns at the talon and fans out to its hand
	_run_bot_turns()


func _restart() -> void:
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

## Keeps letting bots act, one at a time, until only the human can move (or the
## game ends). Runs alongside the human: while it waits out `bot_delay` the
## board is live, and a human move bumps `_turn_epoch`, which makes this loop
## bail so a fresh one can start after that move's animation.
func _run_bot_turns() -> void:
	var run_id := _game_id
	var epoch := _turn_epoch
	while not game.is_finished():
		if run_id != _game_id or epoch != _turn_epoch:
			return
		var action: Dictionary = Bot.pick(game, human_seat)
		if action.is_empty():
			return # only the human can move now
		if bot_delay > 0.0:
			await _wait(bot_delay) # the board stays live during this pause
		else:
			await get_tree().process_frame
		if run_id != _game_id or epoch != _turn_epoch or game.is_finished():
			return
		if _busy: # a human move slipped in and is animating; re-pick next loop
			await _wait(0.05)
			continue
		await _apply_and_animate(action)


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
		await _wait(play_beat)
		if run_id != _game_id: return

	# 2. clear the table
	if not discarded.is_empty():
		for card in discarded:
			_animate_view_away(card)
		_sync_back_stack(_discard_stack, mini(game.discard.size(), 5),
			discard_pos, discard_card_height, 1)
		await _wait(clear_beat)
		if run_id != _game_id: return
	elif not taken.is_empty():
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
	while backs.size() < wanted:
		backs.append(_new_back(talon_pos, 4))
	for i in backs.size():
		_animate_to(backs[i], _opponent_slot_pos(seat, i, wanted), 0.0,
			_fit_scale(backs[i], opponent_card_height), refill_anim, 0.0)


func _fit_scale(view: Sprite2D, target_height: float) -> Vector2:
	return Vector2.ONE * (target_height / maxf(view.texture.get_height(), 1.0))


# ---------------------------------------------------------------- human actions

func _human_actions() -> Array:
	if human_seat < 0 or game == null or game.is_finished():
		return []
	return game.get_legal_actions(human_seat)


func _submit(action: Dictionary) -> void:
	if _busy:
		return # a move is already animating; ignore this one
	_turn_epoch += 1 # pre-empt the bot loop so it doesn't act on top of us
	_drag = {}
	_hovered_view = null
	await _apply_and_animate(action)
	_run_bot_turns()


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


# ---------------------------------------------------------------- drag & drop

func _unhandled_input(event: InputEvent) -> void:
	if game != null and game.is_finished():
		if event is InputEventKey and event.pressed and event.keycode in \
			[KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
			_restart()
		return
	if not _waiting_for_human:
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

	# 1. dropped onto a specific unbeaten attack -> defend it
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
				_submit(action)
				return

	# 4. no valid target -> let _process glide the card home
	var view: Node2D = _drag.view
	_drag = {}
	if is_instance_valid(view):
		view.z_index = 0


func _process(_delta: float) -> void:
	if not _waiting_for_human:
		return

	var mouse := get_global_mouse_position()
	if not _drag.is_empty():
		if is_instance_valid(_drag.view):
			var dragged: Node2D = _drag.view
			dragged.global_position = dragged.global_position.lerp(
				mouse - _drag.grab_offset, drag_follow)
			dragged.z_index = 100
		return

	_hovered_view = null
	for i in range(_hand_slots.size() - 1, -1, -1):
		if _hand_slot_rect(_hand_slots[i]).has_point(mouse):
			_hovered_view = _hand_slots[i].view
			break

	for slot in _hand_slots:
		var view: Node2D = slot.view
		var raised: bool = view == _hovered_view and slot.playable
		var goal: Vector2 = slot.home_pos + (Vector2(0, -hover_raise) if raised else Vector2.ZERO)
		view.global_position = view.global_position.lerp(goal, hand_follow)
		view.scale = view.scale.lerp(slot.home_scale * (hover_scale if raised else 1.0), hand_follow)
		view.z_index = 60 if view == _hovered_view else 0


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
	# where this seat's cards sit, whether the fan is vertical, and its label offset
	var relative := (seat - _near_seat() + game.num_players) % game.num_players
	match relative:
		0: return {origin = Vector2(960, 965), vertical = false, label_offset = Vector2(-45, -150)}
		1: return {origin = Vector2(140, 540), vertical = true, label_offset = Vector2(-40, -170)}
		2: return {origin = Vector2(960, 120), vertical = false, label_offset = Vector2(-45, 90)}
		_: return {origin = Vector2(1780, 540), vertical = true, label_offset = Vector2(-40, -170)}


func _hand_slot_pos(index: int, hand_size: int) -> Vector2:
	var spacing := minf(64.0, 1000.0 / maxf(hand_size, 1))
	var span := spacing * maxf(hand_size - 1, 0)
	return _seat_layout(_near_seat()).origin + Vector2(-span * 0.5 + index * spacing, 0)


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
	var hand: Array = game.hands[_near_seat()]
	for i in hand.size():
		layout.append({
			card = hand[i], pos = _hand_slot_pos(i, hand.size()),
			rotation = 0.0, height = hand_card_height, z = 10,
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

	if _waiting_for_human:
		for slot in _hand_slots:
			_stop_tween(slot.view) # from here _process owns the hand cards


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
	if card in game.discard:
		destination = discard_pos
	else:
		for seat in game.num_players:
			if seat != _near_seat() and card in game.hands[seat]:
				destination = _seat_layout(seat).origin
				break
	_stop_tween(view)
	var tween := create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(view, "position", destination, clear_anim)
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

	var hand: Array = game.hands[human_seat]
	var playable := _playable_cards()
	for i in hand.size():
		var card: CardData = hand[i]
		var view: Sprite2D = _card_views.get(card)
		if view == null:
			continue
		var can_play: bool = playable.has(card)
		# dim non-playable cards only while the user actually has a card play
		view.modulate.a = 1.0 if (can_play or playable.is_empty()) else 0.4
		_hand_slots.append({
			view = view, card = card, home_pos = _hand_slot_pos(i, hand.size()),
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
	_pass_button.visible = offered.call("pass")
	_take_button.visible = offered.call("take") \
		and (game.phase == DurakGame.Phase.TAKING or _unbeaten_count() > 0)
	_translate_strip.visible = offered.call("translate")


func _unbeaten_count() -> int:
	var count := 0
	for pair in game.table:
		if pair.defense == null:
			count += 1
	return count
