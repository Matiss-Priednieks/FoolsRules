class_name SpecialUI
extends Control
## What special cards show beyond the cards themselves, so nothing important
## is ever just a line of text that fades:
##   - the dossier: a peek (Mirror) opens a manila folder over the player you
##     peeked at, the cards inside face-up. It stays until you click it, then
##     its cards stay pinned to that player's plate as small "intel" chips
##     for as long as they're still in that hand.
##   - sealed folders: everyone else only sees a closed TOP SECRET folder over
##     the target. That's the "only you saw it" language: open = yours,
##     sealed = someone else's.
##   - stamped tags on the seat plates for rules that linger (REFILL 7,
##     MUZZLED NEXT, DEFENDS NEXT...) and table-wide notices by the talon.
##   - ink_box(), the worn red stamp all of the above (and CLEARED) share.
## Overlap: peeks from one action merge into one folder, folders queue rather
## than stack, sealed folders on the same target fan out, tags wrap.

const INK := Color(0.62, 0.1, 0.08)
const MANILA := Color(0.77, 0.67, 0.47)
const PAPER := Color(0.88, 0.83, 0.7)
const DOSSIER_CARD_HEIGHT := 190.0
const CHIP_HEIGHT := 78.0
const SEALED_SECONDS := 2.4
const STAMP_SHADER := "shader_type canvas_item;
uniform float erode = 0.22;
float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
float n(vec2 p) { vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1, 0)), f.x), mix(h(i + vec2(0, 1)), h(i + 1.0), f.x), f.y); }
void fragment() {
	vec2 p = FRAGCOORD.xy;
	float wear = n(p * 0.08) * 0.6 + n(p * 0.5) * 0.4; // blotchy patches + fine grain
	COLOR.a *= smoothstep(erode, erode + 0.2, wear) * 0.9;
}"

var g # game.gd - for card views, plates, seat names and the engine
var _ink_heavy: ShaderMaterial
var _ink_light: ShaderMaterial
var _dossier: Control = null
var _dossier_picks: Array = []
var _queue: Array = [] # dossiers waiting their turn: {title, picks, anchor}
var _intel := {} # seat -> Array[CardData] you've seen in that hand
var _badges := {} # seat (or -1 for the table) -> Control holding tags + chips
var _sealed := {} # target seat -> how many sealed folders are up on it right now


func _init(game_ui) -> void:
	g = game_ui
	mouse_filter = MOUSE_FILTER_IGNORE
	set_anchors_preset(PRESET_FULL_RECT)
	_ink_heavy = _ink_material(0.22)
	_ink_light = _ink_material(0.08)


func _ink_material(erode: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = STAMP_SHADER
	mat.set_shader_parameter("erode", erode)
	return mat


## A rubber-stamped word: worn red ink in a border (a second inner border when
## `double`), on bare felt or, with `paper`, on a little paper label.
func ink_box(text: String, font_size: int, border: int, double := true, paper := false) -> PanelContainer:
	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PAPER if paper else Color.TRANSPARENT
	style.border_color = INK
	style.set_border_width_all(border)
	style.set_corner_radius_all(border + 3)
	style.set_content_margin_all(border + 3)
	box.add_theme_stylebox_override("panel", style)
	var label := Label.new()
	if double:
		var inner: StyleBoxFlat = style.duplicate()
		inner.bg_color = Color.TRANSPARENT
		inner.set_border_width_all(maxi(border / 2, 1))
		inner.set_corner_radius_all(border)
		inner.content_margin_left = font_size * 0.37
		inner.content_margin_right = font_size * 0.37
		inner.content_margin_top = 2
		inner.content_margin_bottom = 2
		label.add_theme_stylebox_override("normal", inner)
	label.add_theme_font_override("font", load("res://assets/fonts/radium-bold.ttf"))
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", INK)
	label.text = text
	label.use_parent_material = true
	box.add_child(label)
	box.material = _ink_light if paper or font_size < 40 else _ink_heavy
	box.mouse_filter = MOUSE_FILTER_IGNORE
	return box


## Slams a stamp down: big and see-through, then lands hard, with the thunk.
func slam(box: Control) -> void:
	box.size = box.get_combined_minimum_size()
	box.pivot_offset = box.size * 0.5
	box.scale = Vector2.ONE * 1.6
	box.modulate.a = 0.0
	var t := box.create_tween().set_parallel().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t.tween_property(box, "scale", Vector2.ONE, 0.13)
	t.tween_property(box, "modulate:a", 1.0, 0.1)
	t.chain().tween_callback(Sfx.stamp)


# ---------------------------------------------------------------- dossier

## Queue a peek for the local player. `picks` = [{card, owner}]; `seat` is
## who it's about (the folder sits by them), -1 for one card from everyone.
func peek(title: String, picks: Array, seat: int) -> void:
	_queue.append({title = title, picks = picks, seat = seat})
	if _dossier == null:
		_open_next()


func dossier_open() -> bool:
	return _dossier != null


func _open_next() -> void:
	if _queue.is_empty():
		return
	var d: Dictionary = _queue.pop_front()
	_dossier_picks = d.picks
	var wrap := Control.new()
	wrap.mouse_filter = MOUSE_FILTER_IGNORE
	var folder := _folder_panel(18)
	folder.mouse_filter = MOUSE_FILTER_STOP
	folder.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed:
			close_dossier())
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = MOUSE_FILTER_IGNORE
	folder.add_child(col)
	col.add_child(_ink_text(d.title, 26))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = MOUSE_FILTER_IGNORE
	col.add_child(row)
	var owners := {}
	for pick in d.picks:
		owners[pick.owner] = true
	for pick in d.picks:
		var cell := VBoxContainer.new()
		cell.mouse_filter = MOUSE_FILTER_IGNORE
		cell.add_child(_card_slot(pick.card, DOSSIER_CARD_HEIGHT))
		if owners.size() > 1: # one card from each player: say whose is whose
			var who := _ink_text(g._display_name(pick.owner), 22)
			who.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cell.add_child(who)
		row.add_child(cell)
	var hint := _ink_text("click to close", 18)
	hint.modulate.a = 0.6
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	col.add_child(hint)
	wrap.add_child(folder)
	add_child(wrap)
	folder.size = folder.get_combined_minimum_size()
	wrap.position = _beside(d.seat, folder.size)
	var stamp := ink_box("TOP SECRET", 30, 4)
	wrap.add_child(stamp)
	stamp.position = Vector2(folder.size.x - 210.0, -22.0)
	stamp.rotation = -0.12
	# slides open: folder first, then the stamp comes down on it
	wrap.pivot_offset = folder.size * 0.5
	wrap.scale = Vector2.ONE * 0.85
	wrap.modulate.a = 0.0
	var t := wrap.create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	t.tween_property(wrap, "scale", Vector2.ONE, 0.22)
	t.tween_property(wrap, "modulate:a", 1.0, 0.15)
	Sfx.fan(-4.0)
	stamp.visible = false
	t.chain().tween_callback(func():
		stamp.visible = true
		slam(stamp))
	_dossier = wrap


## Folder shut: what you saw becomes chips on the owners' plates.
func close_dossier() -> void:
	if _dossier == null:
		return
	for pick in _dossier_picks:
		var seen: Array = _intel.get_or_add(pick.owner, [])
		if pick.card not in seen:
			seen.append(pick.card)
	var old := _dossier
	_dossier = null
	_dossier_picks = []
	var t := old.create_tween().set_parallel()
	t.tween_property(old, "modulate:a", 0.0, 0.18)
	t.tween_property(old, "scale", Vector2.ONE * 0.9, 0.18)
	t.chain().tween_callback(old.queue_free)
	refresh()
	if not _queue.is_empty():
		get_tree().create_timer(0.25).timeout.connect(_open_next)


## Someone else peeked: a closed folder over the target, then gone. Several on
## one target fan out instead of covering each other.
func sealed(target: int, peeker: int) -> void:
	var n: int = _sealed.get(target, 0)
	_sealed[target] = n + 1
	var folder := _folder_panel(12)
	folder.mouse_filter = MOUSE_FILTER_IGNORE
	var col := VBoxContainer.new()
	col.mouse_filter = MOUSE_FILTER_IGNORE
	folder.add_child(col)
	var line := "%s peeked at your cards" % g._display_name(peeker) if target == g.human_seat \
		else "%s peeked" % g._display_name(peeker)
	col.add_child(_ink_text(line, 22))
	col.add_child(ink_box("TOP SECRET", 22, 3))
	add_child(folder)
	folder.size = folder.get_combined_minimum_size()
	folder.position = _beside(target, folder.size) + Vector2(n * 22.0, n * 18.0)
	folder.rotation = randf_range(-0.06, 0.06)
	folder.modulate.a = 0.0
	var t := folder.create_tween()
	t.tween_property(folder, "modulate:a", 1.0, 0.15)
	t.tween_interval(SEALED_SECONDS)
	t.tween_property(folder, "modulate:a", 0.0, 0.3)
	t.tween_callback(func():
		_sealed[target] = maxi(_sealed.get(target, 1) - 1, 0)
		folder.queue_free())
	Sfx.fan(-10.0)


func _folder_panel(margin: int) -> PanelContainer:
	var folder := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = MANILA
	style.border_color = MANILA.darkened(0.45)
	style.set_border_width_all(2)
	style.set_corner_radius_all(5)
	style.set_content_margin_all(margin)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 10
	style.shadow_offset = Vector2(4, 6)
	folder.add_theme_stylebox_override("panel", style)
	return folder


## Dark typewriter-ish ink for writing on paper.
func _ink_text(text: String, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", load("res://assets/fonts/dm-serif.ttf"))
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(0.17, 0.13, 0.09))
	label.mouse_filter = MOUSE_FILTER_IGNORE
	return label


## A real card sprite in a box container: Sprite2D doesn't do layout, so it
## sits centred in a Control sized like the card.
func _card_slot(card: CardData, height: float) -> Control:
	var slot := Control.new()
	slot.custom_minimum_size = Vector2(height * 500.0 / 726.0, height)
	slot.mouse_filter = MOUSE_FILTER_IGNORE
	var view: Sprite2D = g._instance_card()
	view.setup(CardData.SUIT_NAMES[card.suit], card.rank, true)
	g._dress(view, card)
	view.scale = Vector2.ONE * (height / maxf(view.texture.get_height(), 1.0))
	view.position = slot.custom_minimum_size * 0.5
	slot.add_child(view)
	return slot


# ---------------------------------------------------------------- plates: tags + intel

## Rebuild every plate's badges from the engine's state (called on each
## resync). Tags exist exactly as long as the engine says the rule does.
func refresh() -> void:
	if g.game == null:
		return
	for key in _badges:
		_badges[key].queue_free()
	_badges.clear()
	for seat in g.game.num_players:
		var hand: Array = g.game.hands[seat]
		if _intel.has(seat):
			_intel[seat] = _intel[seat].filter(func(c): return c in hand)
		var tags := _tags_for(seat)
		var chips: Array = _intel.get(seat, [])
		if tags.is_empty() and chips.is_empty():
			continue
		_badges[seat] = _badge_column(tags, chips, seat)
	var table_tags: Array[String] = []
	if g.game.joker_shut:
		table_tags.append("JOKER: NO THROW-INS")
	if g.game._turn_direction < 0:
		table_tags.append("PLAY REVERSED")
	if Array(g.game._turn_order) != range(g.game.num_players):
		table_tags.append("SEATS SCRAMBLED")
	if not table_tags.is_empty():
		_badges[-1] = _badge_column(table_tags, [], -1)


func _tags_for(seat: int) -> Array[String]:
	var e = g.game
	var tags: Array[String] = []
	if e._refill_target_override.has(seat):
		tags.append("REFILL %d" % e._refill_target_override[seat])
	if e._refill_priority_seat == seat:
		tags.append("DRAWS FIRST")
	if e._refill_last_seat == seat:
		tags.append("DRAWS LAST")
	if e._refill_from_discard.has(seat):
		tags.append("BLACK MARKET")
	if e._throw_in_locked.has(seat):
		tags.append("NO THROW-INS")
	if e._throw_in_locked_next.has(seat):
		tags.append("MUZZLED NEXT")
	if e._denounced_seat == seat:
		tags.append("DEFENDS NEXT")
	return tags


## Tags in a wrapping row, intel chips under them, hung off the seat's plate:
## below a top seat's plate, above a side seat's, right of your own.
func _badge_column(tags: Array[String], chips: Array, seat: int) -> Control:
	var col := VBoxContainer.new()
	col.mouse_filter = MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 6)
	if not tags.is_empty():
		var flow := HFlowContainer.new()
		flow.mouse_filter = MOUSE_FILTER_IGNORE
		flow.custom_minimum_size.x = 300
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		for tag in tags:
			flow.add_child(ink_box(tag, 20, 2, false, true))
		col.add_child(flow)
	if not chips.is_empty():
		var row := HBoxContainer.new()
		row.mouse_filter = MOUSE_FILTER_IGNORE
		row.add_theme_constant_override("separation", 4)
		for card in chips:
			row.add_child(_card_slot(card, CHIP_HEIGHT))
		col.add_child(row)
	add_child(col)
	col.modulate.a = 0.0 # shown once placed, next frame
	_place_badges.call_deferred(col, seat)
	return col


func _place_badges(col, seat: int) -> void: # untyped: it may be freed by the time this runs
	if not is_instance_valid(col):
		return
	col.size = col.get_combined_minimum_size()
	col.modulate.a = 1.0
	if seat < 0:
		var talon: Control = g._talon_label
		col.position = talon.position + Vector2(talon.size.x + 14.0, 0.0)
		return
	var plate: Control = g._seat_labels[seat]
	var psize := plate.get_combined_minimum_size()
	if seat == g._near_seat():
		col.position = plate.position + Vector2(psize.x + 12.0, 0.0)
	elif g._seat_layout(seat).vertical:
		col.position = plate.position - Vector2(0.0, col.size.y + 8.0)
	else:
		col.position = plate.position + Vector2(0.0, psize.y + 8.0)
	col.position.x = clampf(col.position.x, 8.0, 1912.0 - col.size.x)


## Where a folder about `seat` goes: next to their cards on the table side,
## so it never covers their plate or the corner buttons. -1 = mid-table.
func _beside(seat: int, size: Vector2) -> Vector2:
	var at := Vector2(960, 560) - size * 0.5
	if seat >= 0:
		var lay: Dictionary = g._seat_layout(seat)
		var origin: Vector2 = lay.origin
		if seat == g._near_seat():
			at = Vector2(960.0 - size.x * 0.5, 800.0 - size.y) # over your own hand
		elif lay.vertical:
			var plate: Control = g._seat_labels[seat]
			at.y = maxf(origin.y - size.y * 0.5, plate.position.y + plate.size.y + 12.0) # clear of their plate
			at.x = origin.x + 140.0 if origin.x < 960.0 else origin.x - 140.0 - size.x
		else:
			var plate: Control = g._seat_labels[seat]
			at = Vector2(origin.x - size.x * 0.5, plate.position.y + plate.size.y + 16.0)
	return Vector2(clampf(at.x, 16.0, 1904.0 - size.x), clampf(at.y, 16.0, 1064.0 - size.y))


func reset() -> void:
	_queue.clear()
	if _dossier != null:
		_dossier.queue_free()
		_dossier = null
	_dossier_picks = []
	_intel.clear()
	for key in _badges:
		_badges[key].queue_free()
	_badges.clear()
