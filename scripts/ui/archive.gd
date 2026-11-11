extends Control
## Card Archive: the whole deck and every special card up close, readable
## before a game. Two tabs - The deck (all four suits 2..A plus the trump
## finish and the card back) and Special cards (grouped by category). Hover lifts
## and tilts a card like in play; click opens a close-up with its effect boxes.
##
## Built from what the game already has: card.tscn (+ its hover_follow), the
## CardInfo effect boxes shared with the in-game tooltip, the theme's plate /
## heading styles, the menu's background shader, CRT.warp for the mouse, and
## Transition for leaving.

const CARD_SCENE := preload("res://scenes/card.tscn")
const WORN_PANEL := preload("res://shaders/worn_panel.gdshader")
const CELL := Vector2(176, 250) ## grid slot per card
const CARD_HEIGHT := 210.0
const CLOSEUP_HEIGHT := 780.0
const SPECIALS_PER_ROW := 4 ## cards per row inside a category; more wrap to a new row
const DECK_PER_ROW := 7     ## cards per row for each suit (13 -> 7 + 6)
const FAMILY_ORDER := [
	SpecialCards.Family.ECONOMY, SpecialCards.Family.TABLE_SHAPE, SpecialCards.Family.DEFLECT,
	SpecialCards.Family.SLEIGHT, SpecialCards.Family.HAZARD, SpecialCards.Family.PAYLOAD,
	SpecialCards.Family.JOKER,
]
const SUITS := ["hearts", "diamonds", "clubs", "spades"]
const SUIT_GLYPHS := {"hearts": "♥", "diamonds": "♦", "clubs": "♣", "spades": "♠"}
const RANK_WORDS := {11: "Jack", 12: "Queen", 13: "King", 14: "Ace"}

var _cells: Array[Dictionary] = [] # {cell: Control, view: Sprite2D}
var _hovered: Control
var _pages: Array[Control] = []
var _closeup: Control
var _closeup_view: Sprite2D


func _ready() -> void:
	Dither.layer = Dither.MENU_LAYER # same as the menu: UI on top of the dither
	var back := Button.new()
	back.text = "‹ Back"
	back.theme_type_variation = &"SmallButton"
	back.position = Vector2(80, 54)
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_leave)
	add_child(back)

	var title := Label.new()
	title.theme_type_variation = &"Title"
	title.text = "Card Archive"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size = Vector2(1920, 80)
	title.position = Vector2(0, 36)
	add_child(title)

	# The binder: a worn oilcloth cover (worn_panel.gdshader, as on the plate
	# panels), an aged paper page on it (CardInfo's paper material), three
	# rings down the spine; the cards sit in sleeves on the page.
	var cover := Panel.new()
	cover.theme_type_variation = &"BinderCover"
	var worn := ShaderMaterial.new()
	worn.shader = WORN_PANEL
	cover.material = worn
	cover.position = Vector2(70, 196)
	cover.size = Vector2(1780, 830)
	add_child(cover)
	var paper := Panel.new()
	paper.theme_type_variation = &"BinderPage"
	paper.material = CardInfo.paper_material()
	paper.position = Vector2(118, 214)
	paper.size = Vector2(1712, 794)
	add_child(paper)
	for i in 3:
		var ring := Panel.new()
		ring.theme_type_variation = &"BinderRing"
		ring.position = Vector2(92, 300 + i * 260)
		ring.size = Vector2(60, 34)
		add_child(ring)

	var scroll := ScrollContainer.new()
	scroll.position = Vector2(172, 228)
	scroll.size = Vector2(1640, 770)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(stack)
	_pages = [_build_deck_page(), _build_specials_page()]
	for page in _pages:
		stack.add_child(page)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 16)
	tabs.position = Vector2(960 - 330, 124)
	var group := ButtonGroup.new()
	for i in 2:
		var tab := Button.new()
		tab.text = ["The deck", "Special cards"][i]
		tab.toggle_mode = true
		tab.button_group = group
		tab.focus_mode = Control.FOCUS_NONE
		tab.custom_minimum_size = Vector2(320, 56)
		tab.pressed.connect(_show_page.bind(i))
		tabs.add_child(tab)
	add_child(tabs)
	(tabs.get_child(0) as Button).button_pressed = true
	_show_page(0)


func _exit_tree() -> void:
	Dither.layer = Dither.GAME_LAYER


func _show_page(i: int) -> void:
	for p in _pages.size():
		_pages[p].visible = p == i
	_hovered = null


# ---------------------------------------------------------------- pages

## Categories flow side by side (each: heading, its cards, then its one-liner
## underneath - text of any length never pushes the cards out of line), so the
## small ones share a row instead of leaving most of it empty.
func _build_specials_page() -> Control:
	var page := HFlowContainer.new()
	page.add_theme_constant_override("h_separation", 56)
	page.add_theme_constant_override("v_separation", 28)
	for family in FAMILY_ORDER:
		var ids: Array = SpecialCards.DEFS.keys().filter(
			func(id): return SpecialCards.DEFS[id].family == family)
		if ids.is_empty():
			continue
		var group := VBoxContainer.new()
		group.add_theme_constant_override("separation", 8)
		group.add_child(_heading(SpecialCards.FAMILY_INFO[family][0], SpecialCards.FAMILY_COLORS[family]))
		var cards := GridContainer.new() # a set number per row; more wraps neatly below
		cards.columns = mini(ids.size(), SPECIALS_PER_ROW)
		cards.add_theme_constant_override("h_separation", 6)
		cards.add_theme_constant_override("v_separation", 6)
		for i in ids.size():
			var id: StringName = ids[i]
			var rank := clampi(int(SpecialCards.DEFS[id].get("rank_hint", 6)), 6, 14)
			cards.add_child(_cell({suit = SUITS[i % 4], rank = rank, special = id}))
		group.add_child(cards)
		var blurb := Label.new()
		blurb.theme_type_variation = &"TooltipBody" # dark ink on the page
		blurb.text = SpecialCards.FAMILY_INFO[family][1]
		blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		blurb.custom_minimum_size = Vector2(maxf(ids.size() * (CELL.x + 6.0), 380.0), 0)
		group.add_child(blurb)
		page.add_child(group)
	return page


func _build_deck_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 14)
	var note := Label.new()
	note.theme_type_variation = &"TooltipBody" # dark ink on the page
	note.text = "Up to 4 players play with 6 to Ace; 5 or more use the full 2 to Ace."
	page.add_child(note)
	for suit in SUITS:
		page.add_child(_heading("%s  %s" % [suit.capitalize(), SUIT_GLYPHS[suit]], Color(0.6, 0.55, 0.42)))
		var row := GridContainer.new()
		row.columns = DECK_PER_ROW
		row.add_theme_constant_override("h_separation", 6)
		row.add_theme_constant_override("v_separation", 6)
		for rank in range(2, 15):
			row.add_child(_cell({suit = suit, rank = rank}))
		page.add_child(row)
	page.add_child(_heading("Finishes", Color(0.6, 0.55, 0.42)))
	var looks := _row()
	looks.add_child(_cell({suit = "hearts", rank = 14, trump = true}))
	looks.add_child(_cell({suit = "spades", rank = 6, face = false}))
	page.add_child(looks)
	return page


## A family / suit heading: the seat-plate style, rimmed in `rim`.
func _heading(text: String, rim: Color) -> Label:
	var plate := Label.new()
	plate.theme_type_variation = &"SeatPlate"
	plate.text = text.to_upper()
	plate.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	var sb := get_theme_stylebox("normal", &"SeatPlate").duplicate() as StyleBoxFlat
	sb.border_color = rim
	plate.add_theme_stylebox_override("normal", sb)
	plate.add_theme_font_size_override("font_size", 30)
	return plate


func _row() -> HFlowContainer:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 6)
	row.add_theme_constant_override("v_separation", 6)
	return row


## One grid slot: a real card view (card.tscn), hover-tracked, click to inspect.
func _cell(spec: Dictionary) -> Control:
	var cell := Control.new()
	cell.custom_minimum_size = CELL
	cell.mouse_filter = Control.MOUSE_FILTER_PASS # wheel still scrolls the page
	var sleeve := Panel.new() # the binder's clear plastic pocket
	sleeve.theme_type_variation = &"BinderSleeve"
	sleeve.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sleeve.size = Vector2(CARD_HEIGHT * 500.0 / 726.0, CARD_HEIGHT) + Vector2(16, 16)
	sleeve.position = (CELL - sleeve.size) * 0.5
	cell.add_child(sleeve)
	var view := _make_card(spec, CARD_HEIGHT)
	var h := hash(str(spec))
	var home := CELL * 0.5 + Vector2(float(h % 9) - 4.0, float((h / 9) % 9) - 4.0)
	view.rotation = (float((h / 81) % 100) / 100.0 - 0.5) * 0.08 # +-2.3 degrees
	view.position = home
	view.set_meta("home_pos", home)
	sleeve.rotation = view.rotation
	sleeve.pivot_offset = sleeve.size * 0.5
	sleeve.position += home - CELL * 0.5
	cell.add_child(view)
	cell.mouse_entered.connect(func():
		_hovered = cell
		Sfx.hover())
	cell.mouse_exited.connect(func():
		if _hovered == cell:
			_hovered = null)
	cell.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_open_closeup(spec))
	_cells.append({cell = cell, view = view})
	return cell


func _make_card(spec: Dictionary, height: float) -> Sprite2D:
	var view: Sprite2D = CARD_SCENE.instantiate()
	view.setup(spec.suit, spec.rank, spec.get("face", true))
	if spec.has("special"):
		view.set_special(spec.special)
	if spec.get("trump", false):
		view.set_trump_shimmer(true)
	view.scale = Vector2.ONE * (height / 726.0)
	view.set_meta("home_scale", view.scale)
	return view


# ---------------------------------------------------------------- close-up

func _open_closeup(spec: Dictionary) -> void:
	_close_closeup()
	Sfx.fan(-6.0)
	_hovered = null
	_closeup = Control.new()
	_closeup.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_closeup)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			_close_closeup())
	_closeup.add_child(dim)

	_closeup_view = _make_card(spec, CLOSEUP_HEIGHT)
	_closeup_view.position = Vector2(560, 545)
	_closeup.add_child(_closeup_view)

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 18)
	info.position = Vector2(1010, 190)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_closeup.add_child(info)
	var name_label := Label.new()
	name_label.theme_type_variation = &"Heading"
	name_label.text = _card_title(spec)
	info.add_child(name_label)
	if spec.has("special"):
		var family: int = SpecialCards.DEFS[spec.special].family
		info.add_child(_heading(SpecialCards.FAMILY_INFO[family][0], SpecialCards.FAMILY_COLORS[family]))
		for box in CardInfo.boxes(spec.special, true):
			info.add_child(box)
	else:
		info.add_child(CardInfo.box(_card_title(spec), _plain_text(spec), &"TooltipCard", true))
	var hint := Label.new()
	hint.theme_type_variation = &"HudDim"
	hint.text = "Click anywhere or press Esc to close"
	info.add_child(hint)


func _close_closeup() -> void:
	if _closeup != null:
		_closeup.queue_free()
		_closeup = null
		_closeup_view = null


func _card_title(spec: Dictionary) -> String:
	if spec.has("special"):
		return SpecialCards.DEFS[spec.special].name
	if not spec.get("face", true):
		return "Card back"
	var rank: String = RANK_WORDS.get(spec.rank, str(spec.rank))
	return "%s of %s" % [rank, String(spec.suit).capitalize()]


func _plain_text(spec: Dictionary) -> String:
	if not spec.get("face", true):
		return "What everyone else sees of your hand."
	if spec.get("trump", false):
		return "Cards of the trump suit get the copper finish. A trump beats any card of another suit; the trump suit is turned up at the start of each game."
	return "An ordinary card. It beats a lower card of its own suit; any trump beats it."


# ---------------------------------------------------------------- input / hover

func _process(_delta: float) -> void:
	var mouse := CRT.warp(get_global_mouse_position())
	for c in _cells:
		var cell: Control = c.cell
		if not cell.is_visible_in_tree():
			continue
		var view: Sprite2D = c.view
		var hovered := cell == _hovered and _closeup == null
		var local_mouse: Vector2 = cell.get_global_transform().affine_inverse() * mouse
		view.hover_follow(local_mouse, hovered, view.get_meta("home_pos"), view.get_meta("home_scale"), 0.25, 1.15, 14.0, 14.0)
		view.z_index = 5 if hovered else 0
	if _closeup_view != null: # the close-up always leans toward the mouse
		_closeup_view.hover_follow(mouse, true, Vector2(560, 545), _closeup_view.get_meta("home_scale"),
			0.15, 1.0, 0.0, 10.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _closeup != null:
			_close_closeup()
		else:
			_leave()


func _leave() -> void:
	Transition.change_scene("res://scenes/menu.tscn")
