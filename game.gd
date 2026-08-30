extends Node2D
## Phase 3c/3d/3e: seat `human_seat` is the user (Slay-the-Spire drag), the other
## seats are Bot. Every card has ONE persistent view node kept in `_views`, keyed
## by its CardData; on each state change the views tween to their new homes
## (cubic ease-out) so pickups, refills and bouts are followable. Hidden zones
## (bot hands, talon body, discard) are drawn as pools of card-backs.

const CardScene := preload("res://card.tscn")
const SUITS := ["clubs", "diamonds", "hearts", "spades"]
const SUIT_GLYPH := ["♣", "♦", "♥", "♠"]

const CENTER := Vector2(960, 540)
const HAND_H := 200.0
const TABLE_H := 140.0
const TALON_H := 140.0
const BOT_H := 118.0
const DISCARD_H := 130.0
const MOVE_DUR := 0.30

const TALON_BASE := Vector2(250, 560)
const DISCARD_BASE := Vector2(1690, 560)
const TABLE_RECT := Rect2(500, 350, 920, 380)
const XLATE_RECT := Rect2(660, 232, 600, 96)

@export var bot_delay := 0.7
@export var human_seat := 0 # -1 = watch mode (all bots)

var game: DurakGame

var _board: Node2D
var _ui: CanvasLayer
var _hud: Label
var _btn_take: Button
var _btn_pass: Button
var _xlate_bg: ColorRect
var _talon_label: Label
var _discard_label: Label
var _seat_labels: Array[Label] = []
var _panel: ColorRect
var _panel_title: Label
var _panel_list: Label

var _views: Dictionary = {}      # CardData -> Sprite2D
var _bot_backs: Dictionary = {}  # seat -> Array[Sprite2D]
var _talon_backs: Array[Sprite2D] = []
var _discard_backs: Array[Sprite2D] = []

var _dirty := false
var _gen := 0  # bumped on new game so a suspended _advance() from the old one bails
var _interactive := false
var _hand_cards: Array = []  # [{node, data, home, home_scale, playable}]
var _table_atk: Array = []   # [{node, index}] unbeaten attacks
var _held := {}              # {node, data, home, grab}
var _hover: Node = null
var _last_table_n := 0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		bot_delay = 0.0
		human_seat = -1 # let the smoke test self-play

	_board = Node2D.new()
	add_child(_board)
	_ui = CanvasLayer.new()
	add_child(_ui)

	_hud = _mk_label(Vector2(24, 18), 22)
	_talon_label = _mk_label(TALON_BASE + Vector2(-40, 96), 18)
	_discard_label = _mk_label(DISCARD_BASE + Vector2(-40, 96), 18)
	for i in 4:
		_seat_labels.append(_mk_label(Vector2.ZERO, 18))

	_btn_take = _mk_button("Take", Vector2(1520, 690), _on_take)
	_btn_pass = _mk_button("Pass", Vector2(1520, 770), _on_pass)

	_xlate_bg = ColorRect.new()
	_xlate_bg.color = Color(0.9, 0.75, 0.2, 0.22)
	_xlate_bg.position = XLATE_RECT.position
	_xlate_bg.size = XLATE_RECT.size
	_xlate_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_xlate_bg.visible = false
	var xl := Label.new()
	xl.text = "▲  drop here — pass the attack on"
	xl.size = XLATE_RECT.size
	xl.add_theme_font_size_override("font_size", 20)
	xl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	xl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	xl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_xlate_bg.add_child(xl)
	_ui.add_child(_xlate_bg)

	_build_panel()

	RenderingServer.set_default_clear_color(Color(0.05, 0.22, 0.12))
	_new_game()


func _mk_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(l)
	return l


func _mk_button(text: String, pos: Vector2, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(150, 60)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 22)
	b.pressed.connect(cb)
	b.visible = false
	_ui.add_child(b)
	return b


func _build_panel() -> void:
	_panel = ColorRect.new()
	_panel.color = Color(0.03, 0.05, 0.04, 0.78)
	_panel.position = Vector2.ZERO
	_panel.size = Vector2(1920, 1080)
	_panel.visible = false
	_ui.add_child(_panel)

	_panel_title = Label.new()
	_panel_title.position = Vector2(0, 300)
	_panel_title.size = Vector2(1920, 80)
	_panel_title.add_theme_font_size_override("font_size", 56)
	_panel_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(_panel_title)

	_panel_list = Label.new()
	_panel_list.position = Vector2(0, 430)
	_panel_list.size = Vector2(1920, 220)
	_panel_list.add_theme_font_size_override("font_size", 28)
	_panel_list.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(_panel_list)

	var again := Button.new()
	again.text = "Play again  (Space)"
	again.add_theme_font_size_override("font_size", 26)
	again.size = Vector2(320, 72)
	again.position = Vector2(960 - 160, 700)
	again.focus_mode = Control.FOCUS_NONE
	again.pressed.connect(_reset)
	_panel.add_child(again)


# ---------------------------------------------------------------- game lifecycle

func _new_game() -> void:
	_gen += 1
	game = DurakGame.new(4, 0)
	game.state_changed.connect(_on_state_changed)
	game.game_over.connect(_on_game_over)
	_last_table_n = 0
	_sync()
	_advance()


func _reset() -> void:
	_panel.visible = false
	for v in _views.values():
		if is_instance_valid(v):
			v.queue_free()
	_views.clear()
	for arr in _bot_backs.values():
		for b in arr:
			if is_instance_valid(b):
				b.queue_free()
	_bot_backs.clear()
	for b in _talon_backs + _discard_backs:
		if is_instance_valid(b):
			b.queue_free()
	_talon_backs.clear()
	_discard_backs.clear()
	_hand_cards.clear()
	_table_atk.clear()
	_held = {}
	_hover = null
	if game != null:
		if game.state_changed.is_connected(_on_state_changed):
			game.state_changed.disconnect(_on_state_changed)
		if game.game_over.is_connected(_on_game_over):
			game.game_over.disconnect(_on_game_over)
	_new_game()


func _on_state_changed() -> void:
	_dirty = true # coalesce a burst of emits into one _sync next frame


func _on_game_over(loser: int) -> void:
	print("game over - durak is %s" % ("draw" if loser < 0 else "P%d" % loser))
	if DisplayServer.get_name() == "headless":
		get_tree().quit()
		return
	_show_panel_soon(loser)


func _show_panel_soon(loser: int) -> void:
	var my_gen := _gen
	await get_tree().create_timer(0.55).timeout
	if my_gen != _gen:
		return
	if loser < 0:
		_panel_title.text = "Draw"
	elif human_seat == loser:
		_panel_title.text = "You are the durak"
	elif human_seat >= 0:
		var place := game.finish_order.find(human_seat)
		_panel_title.text = "You got out %s" % ["1st", "2nd", "3rd", "4th"][maxi(place, 0)]
	else:
		_panel_title.text = "P%d is the durak" % loser
	var lines: Array[String] = []
	for i in game.finish_order.size():
		var seat: int = game.finish_order[i]
		var who := "You" if seat == human_seat else "P%d" % seat
		var mark := "durak" if i == game.finish_order.size() - 1 else "safe"
		lines.append("%d.  %s  —  %s" % [i + 1, who, mark])
	_panel_list.text = "\n".join(lines)
	_panel.visible = true


# ---------------------------------------------------------------- bot turn loop

func _advance() -> void:
	var my_gen := _gen
	if game.is_finished():
		return
	var actors := game.players_to_act()
	if actors.is_empty():
		return
	if human_seat >= 0 and actors.size() == 1 and actors[0] == human_seat:
		return

	var extra := 0.45 if (game.table.is_empty() and _last_table_n > 0) else 0.0
	_last_table_n = game.table.size()
	if bot_delay > 0.0 or extra > 0.0:
		await get_tree().create_timer(bot_delay + extra).timeout
	else:
		await get_tree().process_frame
	if my_gen != _gen or game.is_finished():
		return

	var action: Dictionary = Bot.pick(game, human_seat)
	if action.is_empty():
		return
	game.apply_action(action)
	_last_table_n = game.table.size()
	_advance()


# ---------------------------------------------------------------- human actions

func _human_acts() -> Array:
	if human_seat < 0 or game == null or game.is_finished():
		return []
	return game.get_legal_actions(human_seat)


func _do(action: Dictionary) -> void:
	_held = {}
	_hover = null
	game.apply_action(action)
	_advance()


func _on_take() -> void:
	for a in _human_acts():
		if a.type == "take":
			_do(a)
			return


func _on_pass() -> void:
	for a in _human_acts():
		if a.type == "pass":
			_do(a)
			return


# ---------------------------------------------------------------- drag & drop

func _unhandled_input(event: InputEvent) -> void:
	if game != null and game.is_finished():
		if event is InputEventKey and event.pressed and event.keycode in \
			[KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
			_reset()
		return
	if not _interactive:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_grab()
		else:
			_try_drop()


func _try_grab() -> void:
	if not _held.is_empty():
		return
	var mp := get_global_mouse_position()
	for i in range(_hand_cards.size() - 1, -1, -1):
		var hc: Dictionary = _hand_cards[i]
		if hc.playable and _slot_rect(hc).has_point(mp):
			_kill_tween(hc.node)
			_held = {
				node = hc.node, data = hc.data, home = hc.home,
				grab = mp - hc.node.global_position,
			}
			hc.node.z_index = 100
			return


func _try_drop() -> void:
	if _held.is_empty():
		return
	var mp := get_global_mouse_position()
	var acts := _human_acts()

	for t in _table_atk:
		if _node_rect(t.node).grow(14).has_point(mp):
			for a in acts:
				if a.type == "defend" and a.card == _held.data and a.target == t.index:
					_do(a)
					return

	if _xlate_bg.visible and XLATE_RECT.has_point(mp):
		for a in acts:
			if a.type == "translate" and a.card == _held.data:
				_do(a)
				return

	if TABLE_RECT.has_point(mp):
		for a in acts:
			if a.type == "attack" and a.card == _held.data:
				_do(a)
				return

	var n = _held.node
	_held = {}
	if is_instance_valid(n):
		n.z_index = 0


func _process(_dt: float) -> void:
	if _dirty:
		_dirty = false
		_sync()
	if not _interactive:
		return

	var mp := get_global_mouse_position()
	if not _held.is_empty():
		if is_instance_valid(_held.node):
			var held: Node2D = _held.node
			held.global_position = held.global_position.lerp(mp - _held.grab, 0.4)
			held.z_index = 100
		return

	_hover = null
	for i in range(_hand_cards.size() - 1, -1, -1):
		if _slot_rect(_hand_cards[i]).has_point(mp):
			_hover = _hand_cards[i].node
			break

	for hc in _hand_cards:
		var n: Node2D = hc.node
		var raised: bool = n == _hover and hc.playable
		var target: Vector2 = hc.home + (Vector2(0, -46) if raised else Vector2.ZERO)
		n.global_position = n.global_position.lerp(target, 0.3)
		n.scale = n.scale.lerp(hc.home_scale * (1.12 if raised else 1.0), 0.3)
		n.z_index = 60 if n == _hover else 0


func _slot_rect(hc: Dictionary) -> Rect2:
	var sz: Vector2 = hc.node.texture.get_size() * hc.home_scale
	return Rect2(hc.home - sz * 0.5, sz)


func _node_rect(n: Node2D) -> Rect2:
	var sz: Vector2 = n.texture.get_size() * n.scale
	return Rect2(n.global_position - sz * 0.5, sz)


# ---------------------------------------------------------------- view sync

func _bottom_seat() -> int:
	return human_seat if human_seat >= 0 else 0


func _seat_anchor(seat: int) -> Dictionary:
	var rel := (seat - _bottom_seat() + game.num_players) % game.num_players
	match rel:
		0: return {pos = Vector2(960, 965), vertical = false, tag = Vector2(-45, -150)}
		1: return {pos = Vector2(140, 540), vertical = true, tag = Vector2(-40, -170)}
		2: return {pos = Vector2(960, 120), vertical = false, tag = Vector2(-45, 90)}
		_: return {pos = Vector2(1780, 540), vertical = true, tag = Vector2(-40, -170)}


func _hand_slot(i: int, n: int) -> Vector2:
	var step := minf(64.0, 1000.0 / maxf(n, 1))
	var span := step * maxf(n - 1, 0)
	return _seat_anchor(_bottom_seat()).pos + Vector2(-span * 0.5 + i * step, 0)


func _bot_slot(seat: int, i: int, n: int) -> Vector2:
	var a := _seat_anchor(seat)
	var step := 26.0
	var span := step * maxf(n - 1, 0)
	var d := -span * 0.5 + i * step
	return a.pos + (Vector2(0, d) if a.vertical else Vector2(d, 0))


func _table_slot(i: int, n: int, defense: bool) -> Vector2:
	var step := 165.0
	var x0 := CENTER.x - step * maxf(n - 1, 0) * 0.5
	return Vector2(x0 + i * step, CENTER.y - 12) + (Vector2(30, 44) if defense else Vector2.ZERO)


func _visible_targets() -> Array:
	var out: Array = []
	var hand: Array = game.hands[_bottom_seat()]
	for i in hand.size():
		out.append({card = hand[i], pos = _hand_slot(i, hand.size()), rot = 0.0, h = HAND_H})
	var n := game.table.size()
	for i in n:
		var pair: Dictionary = game.table[i]
		out.append({card = pair.attack, pos = _table_slot(i, n, false), rot = 0.0, h = TABLE_H})
		if pair.defense != null:
			out.append({card = pair.defense, pos = _table_slot(i, n, true), rot = 0.14, h = TABLE_H})
	if game.trump_card in game.deck:
		out.append({card = game.trump_card, pos = TALON_BASE + Vector2(60, 0),
			rot = PI * 0.5, h = TALON_H})
	return out


func _sync() -> void:
	if game == null:
		return
	var pa := game.players_to_act()
	_interactive = not game.is_finished() and pa.size() == 1 and pa[0] == human_seat

	var targets := _visible_targets()
	var seen := {}
	var fresh := 0
	for t in targets:
		seen[t.card] = true
		var v: Sprite2D = _views.get(t.card)
		var delay := 0.0
		if v == null:
			v = _spawn_view(t.card)
			_views[t.card] = v
			delay = fresh * 0.05
			fresh += 1
		var scl: Vector2 = Vector2.ONE * (float(t.h) / maxf(v.texture.get_height(), 1.0))
		_move(v, t.pos, t.rot, scl, MOVE_DUR, delay)

	for card in _views.keys():
		if not seen.has(card):
			_fly_out(card)

	_sync_stack(_talon_backs, maxi(game.talon_count() - 1, 0), TALON_BASE, TALON_H, -1)
	_sync_stack(_discard_backs, mini(game.discard.size(), 5), DISCARD_BASE, DISCARD_H, 1)
	_talon_label.text = "talon  %d" % game.talon_count()
	_talon_label.visible = game.talon_count() > 0
	_discard_label.text = "discard  %d" % game.discard.size()
	_discard_label.visible = game.discard.size() > 0
	_sync_bots()

	_refresh_interaction()
	_update_hud()
	_sync_ui()

	if _interactive:
		for hc in _hand_cards:
			_kill_tween(hc.node) # hand cards are now driven by _process


func _spawn_view(card: CardData) -> Sprite2D:
	var v := _fresh_card()
	v.setup(SUITS[card.suit], card.rank, true)
	v.position = _spawn_from(card)
	v.scale = Vector2.ONE * (TALON_H / maxf(v.texture.get_height(), 1.0))
	v.z_index = 10
	_board.add_child(v)
	return v


func _spawn_from(card: CardData) -> Vector2:
	for i in game.table.size():
		if game.table[i].attack == card:
			return _seat_anchor(game.attacker).pos
		if game.table[i].defense == card:
			return _seat_anchor(game.defender).pos
	return TALON_BASE


func _fly_out(card: CardData) -> void:
	var v: Sprite2D = _views[card]
	_views.erase(card)
	var dest := TALON_BASE
	if card in game.discard:
		dest = DISCARD_BASE
	else:
		for s in game.num_players:
			if s != _bottom_seat() and card in game.hands[s]:
				dest = _seat_anchor(s).pos
				break
	_kill_tween(v)
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(v, "position", dest, 0.36)
	tw.tween_property(v, "scale", v.scale * 0.6, 0.36)
	tw.tween_property(v, "modulate:a", 0.0, 0.36)
	tw.chain().tween_callback(v.queue_free)


func _sync_stack(arr: Array, want: int, base: Vector2, h: float, dir: int) -> void:
	want = clampi(want, 0, 12)
	while arr.size() < want:
		var b := _fresh_card()
		b.setup("clubs", 6, false)
		b.position = base
		b.z_index = 5
		_board.add_child(b)
		arr.append(b)
	while arr.size() > want:
		_fade_free(arr.pop_back())
	for i in arr.size():
		var b: Sprite2D = arr[i]
		var scl := Vector2.ONE * (h / maxf(b.texture.get_height(), 1.0))
		_move(b, base + Vector2(i * 1.6 * dir, -i * 1.9), 0.0, scl, MOVE_DUR, 0.0)


func _sync_bots() -> void:
	for seat in game.num_players:
		if seat == _bottom_seat():
			_seat_labels[seat].visible = human_seat >= 0
			if human_seat >= 0:
				_place_seat_label(seat)
			continue
		var n: int = game.hands[seat].size()
		if not _bot_backs.has(seat):
			_bot_backs[seat] = []
		var arr: Array = _bot_backs[seat]
		while arr.size() < n:
			var b := _fresh_card()
			b.setup("clubs", 6, false)
			b.position = TALON_BASE
			b.z_index = 4
			_board.add_child(b)
			arr.append(b)
		while arr.size() > n:
			_fade_free(arr.pop_back())
		for i in arr.size():
			var b: Sprite2D = arr[i]
			var scl := Vector2.ONE * (BOT_H / maxf(b.texture.get_height(), 1.0))
			_move(b, _bot_slot(seat, i, n), 0.0, scl, MOVE_DUR, 0.0)
		_place_seat_label(seat)


func _place_seat_label(seat: int) -> void:
	var a := _seat_anchor(seat)
	var role := ""
	if not game.is_finished():
		if seat == game.attacker:
			role = "  ▶ attacker"
		elif seat == game.defender:
			role = "  ◀ defender"
	var who := "You" if seat == human_seat else "P%d" % seat
	var l := _seat_labels[seat]
	l.text = "%s   (%d)%s" % [who, game.hands[seat].size(), role]
	l.add_theme_color_override("font_color", Color.GOLD if role != "" else Color.WHITE)
	l.position = a.pos + a.tag


func _fresh_card() -> Sprite2D:
	return CardScene.instantiate()


func _move(v: Node2D, pos: Vector2, rot: float, scl: Vector2, dur: float, delay: float) -> void:
	_kill_tween(v)
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(v, "position", pos, dur).set_delay(delay)
	tw.tween_property(v, "rotation", rot, dur).set_delay(delay)
	tw.tween_property(v, "scale", scl, dur).set_delay(delay)
	v.set_meta("tw", tw)


func _kill_tween(v: Node2D) -> void:
	if v.has_meta("tw"):
		var t = v.get_meta("tw")
		if is_instance_valid(t):
			t.kill()
		v.remove_meta("tw")


func _fade_free(b: Node2D) -> void:
	_kill_tween(b)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(b, "modulate:a", 0.0, 0.22)
	tw.tween_property(b, "scale", b.scale * 0.7, 0.22)
	tw.chain().tween_callback(b.queue_free)


# ---------------------------------------------------------------- interaction refs / hud

func _refresh_interaction() -> void:
	_hand_cards.clear()
	_table_atk.clear()
	if human_seat < 0 or game.is_finished():
		return
	var hand: Array = game.hands[human_seat]
	var playable := _playable_set()
	for i in hand.size():
		var card: CardData = hand[i]
		var v: Sprite2D = _views.get(card)
		if v == null:
			continue
		var can_play: bool = playable.has(card)
		v.modulate.a = 1.0 if (can_play or playable.is_empty()) else 0.4
		_hand_cards.append({
			node = v, data = card, home = _hand_slot(i, hand.size()),
			home_scale = Vector2.ONE * (HAND_H / maxf(v.texture.get_height(), 1.0)),
			playable = can_play,
		})
	for i in game.table.size():
		if game.table[i].defense == null:
			var v: Sprite2D = _views.get(game.table[i].attack)
			if v != null:
				_table_atk.append({node = v, index = i})


func _playable_set() -> Dictionary:
	var out := {}
	for act in _human_acts():
		if act.has("card"):
			out[act.card] = true
	return out


func _update_hud() -> void:
	if game.is_finished():
		_hud.text = ""
		return
	var phase_name: String = ["ATTACK", "DEFEND", "TAKING", "OVER"][game.phase]
	var trump_name: String = CardData.RANK_NAMES.get(
		game.trump_card.rank, str(game.trump_card.rank))
	var you := ""
	if human_seat == game.attacker:
		you = "     — YOU attack"
	elif human_seat == game.defender:
		you = "     — YOU defend"
	_hud.text = "trump %s%s     %s     talon %d  discard %d%s" % [
		trump_name, SUIT_GLYPH[game.trump_suit], phase_name,
		game.talon_count(), game.discard.size(), you,
	]


func _sync_ui() -> void:
	var acts := _human_acts()
	var has_type := func(t: String) -> bool:
		return acts.any(func(a): return a.type == t)
	_btn_pass.visible = has_type.call("pass")
	_btn_take.visible = has_type.call("take") \
		and (game.phase == DurakGame.Phase.TAKING or _unbeaten() > 0)
	_xlate_bg.visible = has_type.call("translate")


func _unbeaten() -> int:
	var k := 0
	for p in game.table:
		if p.defense == null:
			k += 1
	return k
