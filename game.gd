extends Node2D
## Phase 3a/3b: owns one DurakGame and rebuilds the whole board from its state
## on every change. All four seats are currently played by Bot; seat `human_seat`
## becomes interactive in Phase 3c.

const CardScene := preload("res://card.tscn")
const SUITS := ["clubs", "diamonds", "hearts", "spades"]
const SUIT_GLYPH := ["♣", "♦", "♥", "♠"]

const CENTER := Vector2(960, 540)
const HAND_H := 200.0
const SMALL_H := 130.0
const TABLE_H := 150.0

@export var bot_delay := 0.55
@export var human_seat := -1  # -1 = watch mode (all bots)

var game: DurakGame
var _board: Node2D
var _hud: Label


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		bot_delay = 0.0

	_board = Node2D.new()
	add_child(_board)

	_hud = Label.new()
	_hud.position = Vector2(24, 18)
	_hud.add_theme_font_size_override("font_size", 22)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	add_child(_hud)

	RenderingServer.set_default_clear_color(Color(0.05, 0.22, 0.12))
	_new_game()


func _new_game() -> void:
	game = DurakGame.new(4, 0)
	game.state_changed.connect(_render)
	game.game_over.connect(_on_game_over)
	_render()
	_advance()


# ---------------------------------------------------------------- bot turn loop

func _advance() -> void:
	if game.is_finished():
		return
	var actors := game.players_to_act()
	if actors.is_empty():
		return
	if human_seat >= 0 and actors.size() == 1 and actors[0] == human_seat:
		return  # wait for human input (Phase 3c)

	if bot_delay > 0.0:
		await get_tree().create_timer(bot_delay).timeout
	else:
		await get_tree().process_frame
	if game.is_finished():
		return

	var action: Dictionary = Bot.pick(game, human_seat)
	if action.is_empty():
		return
	game.apply_action(action)  # emits state_changed -> _render
	_advance()


func _on_game_over(loser: int) -> void:
	var who := "draw" if loser < 0 else "P%d" % loser
	print("game over - durak is %s" % who)
	if DisplayServer.get_name() == "headless":
		get_tree().quit()


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
	for c in _board.get_children():
		c.queue_free()

	_render_talon_and_discard()
	_render_table()
	for seat in game.num_players:
		if seat == _bottom_seat():
			_render_hand(seat)
		else:
			_render_opponent(seat)
	_update_hud()


func _make_card(suit: int, rank: int, face_up: bool, target_h: float) -> Sprite2D:
	var s: Sprite2D = CardScene.instantiate()
	s.setup(SUITS[suit], rank, face_up)
	var th := s.texture.get_height() if s.texture else 0
	if th > 0:
		s.scale = Vector2.ONE * (target_h / th)
	return s


func _render_hand(seat: int) -> void:
	var a := _seat_anchor(seat)
	var cards: Array = game.hands[seat]
	var step := minf(58.0, 900.0 / maxf(cards.size(), 1))
	var span := step * maxf(cards.size() - 1, 0)
	for i in cards.size():
		var cd: CardData = cards[i]
		var s := _make_card(cd.suit, cd.rank, true, HAND_H)
		s.position = a.pos + Vector2(-span * 0.5 + i * step, 0)
		_board.add_child(s)
	_add_seat_tag(seat, a)


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
		if pair.defense != null:
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
		_hud.text = "GAME OVER  -  durak is P%d       (restart: Phase 3d)" % game.loser \
			if game.loser >= 0 else "GAME OVER  -  draw"
		return
	var phase_name: String = ["ATTACK", "DEFEND", "TAKING", "OVER"][game.phase]
	var trump_name: String = CardData.RANK_NAMES.get(
		game.trump_card.rank, str(game.trump_card.rank))
	_hud.text = "trump %s%s        %s        attacker P%d   defender P%d        talon %d   discard %d" % [
		trump_name, SUIT_GLYPH[game.trump_suit], phase_name,
		game.attacker, game.defender, game.talon_count(), game.discard.size(),
	]
