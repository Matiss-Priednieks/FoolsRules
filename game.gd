extends Node2D
## Phase 3c: seat `human_seat` is the user. Slay-the-Spire-style click-drag on
## hand cards: hover raises a card, grab it, then
##   - drop on the table            -> attack / throw in
##   - drop onto an unbeaten attack  -> defend that card
##   - drop on the "pass it on" strip -> translate (perevod)
## Take / Pass are buttons. The other three seats are played by Bot.

const CardScene := preload("res://card.tscn")
const SUITS := ["clubs", "diamonds", "hearts", "spades"]
const SUIT_GLYPH := ["♣", "♦", "♥", "♠"]

const CENTER := Vector2(960, 540)
const HAND_H := 200.0
const SMALL_H := 130.0
const TABLE_H := 150.0

const TABLE_RECT := Rect2(500, 350, 920, 380)
const XLATE_RECT := Rect2(660, 232, 600, 96)

@export var bot_delay := 0.55
@export var human_seat := 0 # -1 = watch mode (all bots)

var game: DurakGame
var _board: Node2D
var _ui: CanvasLayer
var _hud: Label
var _btn_take: Button
var _btn_pass: Button
var _xlate_bg: ColorRect

var _interactive := false
var _hand_cards: Array = [] # [{node, data, home, home_scale, playable}]
var _table_atk: Array = []  # [{node, index}] for unbeaten attacks
var _held := {}             # {node, data, home, grab}
var _hover: Node = null


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		bot_delay = 0.0
		human_seat = -1 # let the smoke test self-play

	_board = Node2D.new()
	add_child(_board)

	_ui = CanvasLayer.new()
	add_child(_ui)

	_hud = Label.new()
	_hud.position = Vector2(24, 18)
	_hud.add_theme_font_size_override("font_size", 22)
	_ui.add_child(_hud)

	_btn_take = _make_button("Take", Vector2(1520, 700), _on_take)
	_btn_pass = _make_button("Pass", Vector2(1520, 780), _on_pass)

	_xlate_bg = ColorRect.new()
	_xlate_bg.color = Color(0.9, 0.75, 0.2, 0.22)
	_xlate_bg.position = XLATE_RECT.position
	_xlate_bg.size = XLATE_RECT.size
	_xlate_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_xlate_bg.visible = false
	var xl := Label.new()
	xl.text = "▲  drop here — pass the attack on"
	xl.add_theme_font_size_override("font_size", 20)
	xl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	xl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	xl.size = XLATE_RECT.size
	_xlate_bg.add_child(xl)
	_ui.add_child(_xlate_bg)

	RenderingServer.set_default_clear_color(Color(0.05, 0.22, 0.12))
	_new_game()


func _make_button(text: String, pos: Vector2, cb: Callable) -> Button:
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


func _new_game() -> void:
	game = DurakGame.new(4, 0)
	game.state_changed.connect(_render)
	game.game_over.connect(_on_game_over)
	_render()
	_advance()


# ---------------------------------------------------------------- turn loop

func _advance() -> void:
	if game.is_finished():
		return
	var actors := game.players_to_act()
	if actors.is_empty():
		return
	if human_seat >= 0 and actors.size() == 1 and actors[0] == human_seat:
		return # board is interactive now; wait for the user

	if bot_delay > 0.0:
		await get_tree().create_timer(bot_delay).timeout
	else:
		await get_tree().process_frame
	if game.is_finished():
		return

	var action: Dictionary = Bot.pick(game, human_seat)
	if action.is_empty():
		return
	game.apply_action(action) # emits state_changed -> _render
	_advance()


func _on_game_over(loser: int) -> void:
	print("game over - durak is %s" % ("draw" if loser < 0 else "P%d" % loser))
	if DisplayServer.get_name() == "headless":
		get_tree().quit()


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
			_new_game()
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

	var n = _held.node # nothing matched -> glide home via _process
	_held = {}
	if is_instance_valid(n):
		n.z_index = 0


func _process(_dt: float) -> void:
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
		var lift := -46.0 if (n == _hover and hc.playable) else 0.0
		var pop := 1.12 if (n == _hover and hc.playable) else 1.0
		n.global_position = n.global_position.lerp(hc.home + Vector2(0, lift), 0.3)
		n.scale = n.scale.lerp(hc.home_scale * pop, 0.3)
		n.z_index = 60 if n == _hover else 0


func _slot_rect(hc: Dictionary) -> Rect2:
	var sz: Vector2 = hc.node.texture.get_size() * hc.home_scale
	return Rect2(hc.home - sz * 0.5, sz)


func _node_rect(n: Node2D) -> Rect2:
	var sz: Vector2 = n.texture.get_size() * n.scale
	return Rect2(n.global_position - sz * 0.5, sz)


# ---------------------------------------------------------------- rendering

func _bottom_seat() -> int:
	return human_seat if human_seat >= 0 else 0


func _seat_anchor(seat: int) -> Dictionary:
	# rel 0 = bottom (us), then clockwise: 1 left, 2 top, 3 right
	var rel := (seat - _bottom_seat() + game.num_players) % game.num_players
	match rel:
		0: return {pos = Vector2(960, 965), vertical = false, tag = Vector2(0, -HAND_H * 0.5 - 26)}
		1: return {pos = Vector2(115, 540), vertical = true, tag = Vector2(0, -180)}
		2: return {pos = Vector2(960, 110), vertical = false, tag = Vector2(0, 95)}
		_: return {pos = Vector2(1805, 540), vertical = true, tag = Vector2(0, -180)}


func _render() -> void:
	_held = {}
	_hover = null
	_hand_cards.clear()
	_table_atk.clear()
	for c in _board.get_children():
		c.queue_free()

	_render_talon_and_discard()
	_render_table()
	for seat in game.num_players:
		if seat == _bottom_seat():
			_render_hand(seat, seat == human_seat)
		else:
			_render_opponent(seat)
	_update_hud()
	_sync_ui()

	var pa := game.players_to_act()
	_interactive = not game.is_finished() and pa.size() == 1 and pa[0] == human_seat


func _make_card(suit: int, rank: int, face_up: bool, target_h: float) -> Sprite2D:
	var s: Sprite2D = CardScene.instantiate()
	s.setup(SUITS[suit], rank, face_up)
	var th: int = s.texture.get_height() if s.texture else 0
	if th > 0:
		s.scale = Vector2.ONE * (target_h / float(th))
	return s


func _render_hand(seat: int, interactive: bool) -> void:
	var a := _seat_anchor(seat)
	var cards: Array = game.hands[seat]
	var step := minf(64.0, 1000.0 / maxf(cards.size(), 1))
	var span := step * maxf(cards.size() - 1, 0)
	var playable := _playable_set() if interactive else {}
	for i in cards.size():
		var cd: CardData = cards[i]
		var s := _make_card(cd.suit, cd.rank, true, HAND_H)
		var home: Vector2 = a.pos + Vector2(-span * 0.5 + i * step, 0)
		s.position = home
		_board.add_child(s)
		if interactive:
			var can_play: bool = playable.has(cd)
			# dim non-playable cards only while the user actually has a card play
			s.modulate.a = 1.0 if (can_play or playable.is_empty()) else 0.4
			_hand_cards.append({
				node = s, data = cd, home = home, home_scale = s.scale, playable = can_play,
			})
	_add_seat_tag(seat, a)


func _playable_set() -> Dictionary:
	var out := {}
	for act in _human_acts():
		if act.has("card"):
			out[act.card] = true
	return out


func _render_opponent(seat: int) -> void:
	var a := _seat_anchor(seat)
	var n: int = game.hands[seat].size()
	var step := 26.0
	var span := step * maxf(n - 1, 0)
	for i in n:
		var s := _make_card(0, 6, false, SMALL_H)
		var off := Vector2(0, -span * 0.5 + i * step) if a.vertical \
			else Vector2(-span * 0.5 + i * step, 0)
		s.position = a.pos + off
		_board.add_child(s)
	_add_seat_tag(seat, a)


func _add_seat_tag(seat: int, a: Dictionary) -> void:
	var role := ""
	if not game.is_finished():
		if seat == game.attacker:
			role = "  attacker"
		elif seat == game.defender:
			role = "  defender"
	var l := Label.new()
	l.text = "P%d  (%d)%s" % [seat, game.hands[seat].size(), role]
	l.add_theme_font_size_override("font_size", 18)
	l.add_theme_color_override("font_color", Color.WHITE if role == "" else Color.GOLD)
	l.position = a.pos + a.tag - Vector2(45, 0)
	_board.add_child(l)


func _render_table() -> void:
	var n := game.table.size()
	var step := 165.0
	var x0 := CENTER.x - step * maxf(n - 1, 0) * 0.5
	for i in n:
		var pair: Dictionary = game.table[i]
		var atk: CardData = pair.attack
		var av := _make_card(atk.suit, atk.rank, true, TABLE_H)
		av.position = Vector2(x0 + i * step, CENTER.y - 12)
		_board.add_child(av)
		if pair.defense == null:
			_table_atk.append({node = av, index = i})
		else:
			var d: CardData = pair.defense
			var dv := _make_card(d.suit, d.rank, true, TABLE_H)
			dv.position = Vector2(x0 + i * step + 30, CENTER.y + 30)
			dv.rotation = 0.14
			_board.add_child(dv)


func _render_talon_and_discard() -> void:
	var base := Vector2(235, 560)
	if game.talon_count() > 0:
		var tc := game.trump_card
		var trump := _make_card(tc.suit, tc.rank, true, SMALL_H)
		trump.position = base + Vector2(38, 0)
		trump.rotation = PI * 0.5
		_board.add_child(trump)
		if game.talon_count() > 1:
			var back := _make_card(0, 6, false, SMALL_H)
			back.position = base
			_board.add_child(back)
	if game.discard.size() > 0:
		var back := _make_card(0, 6, false, SMALL_H)
		back.position = Vector2(1685, 560)
		back.rotation = 0.05
		_board.add_child(back)


func _update_hud() -> void:
	if game.is_finished():
		_hud.text = "GAME OVER  —  durak is P%d        (Space to restart)" % game.loser \
			if game.loser >= 0 else "GAME OVER  —  draw        (Space to restart)"
		return
	var phase_name: String = ["ATTACK", "DEFEND", "TAKING", "OVER"][game.phase]
	var trump_name: String = CardData.RANK_NAMES.get(
		game.trump_card.rank, str(game.trump_card.rank))
	var you := ""
	if human_seat == game.attacker:
		you = "     — YOU attack"
	elif human_seat == game.defender:
		you = "     — YOU defend"
	_hud.text = "trump %s%s     %s     atk P%d  def P%d     talon %d  discard %d%s" % [
		trump_name, SUIT_GLYPH[game.trump_suit], phase_name,
		game.attacker, game.defender, game.talon_count(), game.discard.size(), you,
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
