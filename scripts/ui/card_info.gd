class_name CardInfo
extends RefCounted
## The card-style effect boxes for a special card, shared by the in-game hover
## tooltip (game.gd) and the Card Archive close-up (archive.gd). They look like
## scraps of the card, not UI: aged paper (paper_panel.gdshader), dark worn ink.
## A dual card gets one box per half, told apart by shape and colour, not words:
## attack is a slanted, forward-leaning box with a faded-red rim (a blade);
## defence is an upright shield (square top, rounded bottom), thick slate rim.
## Single-effect cards get one plain upright box.

const PAPER_PANEL := preload("res://shaders/paper_panel.gdshader")
static var _paper_material: ShaderMaterial


## The boxes for special `id`, in order. `big` = the archive's larger size.
static func boxes(id: StringName, big := false) -> Array[Control]:
	var out: Array[Control] = []
	var def: Dictionary = SpecialCards.DEFS[id]
	if def.get("dual", false):
		var names: PackedStringArray = def.name.split(" / ")
		out.append(box(names[0], def.attack.note, &"TooltipAttack", big))
		out.append(box(names[-1], def.defense.note, &"TooltipDefense", big))
	else:
		out.append(box(def.name, def.note, &"TooltipCard", big))
	return out


## The aged-paper material (paper_panel.gdshader), shared by every paper box.
static func paper_material() -> ShaderMaterial:
	if _paper_material == null:
		_paper_material = ShaderMaterial.new()
		_paper_material.shader = PAPER_PANEL
	return _paper_material


static func box(title: String, body: String, style: StringName, big := false) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = style
	panel.material = paper_material()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(col)
	var head := Label.new()
	head.theme_type_variation = &"TooltipTitle"
	head.text = title
	col.add_child(head)
	# body: rich text, so family keywords ("Curse", "Hazards"...) show in
	# their family's colour - styled to match the TooltipBody label look
	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.fit_content = true
	text.scroll_active = false
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.custom_minimum_size = Vector2(560 if big else 360, 0)
	text.add_theme_color_override("default_color", panel.get_theme_color("font_color", &"TooltipBody"))
	text.add_theme_font_size_override("normal_font_size", 30 if big else 22)
	text.text = colour_keywords(body[0].to_upper() + body.substr(1) if body != "" else "")
	col.add_child(text)
	if big:
		head.add_theme_font_size_override("font_size", 40)
	return panel


## Wraps every family keyword in `text` in that family's colour (darkened to
## read on paper), so a card that cares about another family says so at a glance.
static var _keyword_re: RegEx
static func colour_keywords(text: String) -> String:
	if _keyword_re == null:
		_keyword_re = RegEx.create_from_string("\\b(Curses?|Hazards?|Tricks|Refills|Redirect|Attack Rules|Joker)\\b")
	var out := ""
	var at := 0
	for m in _keyword_re.search_all(text):
		out += text.substr(at, m.get_start() - at)
		out += "[color=#%s]%s[/color]" % [keyword_colour(m.get_string()).to_html(false), m.get_string()]
		at = m.get_end()
	return out + text.substr(at)


static func keyword_colour(word: String) -> Color:
	var family: int = {
		"Curse": SpecialCards.Family.PAYLOAD, "Curses": SpecialCards.Family.PAYLOAD,
		"Hazard": SpecialCards.Family.HAZARD, "Hazards": SpecialCards.Family.HAZARD,
		"Tricks": SpecialCards.Family.SLEIGHT, "Refills": SpecialCards.Family.ECONOMY,
		"Redirect": SpecialCards.Family.DEFLECT, "Attack Rules": SpecialCards.Family.TABLE_SHAPE,
		"Joker": SpecialCards.Family.JOKER,
	}[word]
	if family == SpecialCards.Family.PAYLOAD:
		return SpecialCards.FAMILY_OUTLINES[family] # soot won't read on paper; its rust edge does
	if family == SpecialCards.Family.JOKER:
		return Color(0.62, 0.45, 0.05) # the Joker's gold
	return (SpecialCards.FAMILY_COLORS[family] as Color).darkened(0.25)
