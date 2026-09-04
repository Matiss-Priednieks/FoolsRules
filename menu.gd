extends Control
## Main menu + multiplayer lobby room. Built in code (like game.gd's UI) so the
## scene file stays trivial. Three screens: MAIN -> BROWSE -> ROOM.

enum Screen { MAIN, BROWSE, ROOM }

var _screen := Screen.MAIN
var _box: VBoxContainer
var _toast: Label
var _toast_until := 0.0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		_start_singleplayer.call_deferred() # headless run == the self-play smoke test
		return

	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 14)
	_box.custom_minimum_size = Vector2(520, 0)
	center.add_child(_box)

	_toast = Label.new()
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate = Color(1, 0.5, 0.5)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_toast.offset_top = -60
	add_child(_toast)

	SteamLobby.lobby_entered.connect(_on_lobby_entered)
	SteamLobby.lobby_exited.connect(_on_lobby_exited)
	SteamLobby.lobby_error.connect(_flash)
	SteamLobby.members_updated.connect(_render)
	SteamLobby.browse_updated.connect(_render)
	SteamLobby.game_starting.connect(_on_game_starting)

	_render()


func _process(_delta: float) -> void:
	if _toast == null:
		return
	if _toast.text != "" and Time.get_ticks_msec() / 1000.0 > _toast_until:
		_toast.text = ""


# --- screen rendering ---------------------------------------------------

func _render() -> void:
	for child in _box.get_children():
		child.queue_free()
	match _screen:
		Screen.MAIN: _render_main()
		Screen.BROWSE: _render_browse()
		Screen.ROOM: _render_room()


func _render_main() -> void:
	_title("DURAK")
	_button("Singleplayer", _start_singleplayer)
	var mp := _button("Multiplayer", _open_browse)
	if not SteamManager.available:
		mp.disabled = true
		mp.text = "Multiplayer  (Steam not running)"
	_button("Quit", func(): get_tree().quit())


func _render_browse() -> void:
	_title("Multiplayer")
	_button("Host Game", func(): SteamLobby.host(true))
	_button("Refresh List", func(): SteamLobby.refresh_browse())
	if SteamLobby.browse_results.is_empty():
		_label("No open lobbies. Host one, or Refresh.")
	else:
		for entry in SteamLobby.browse_results:
			var e: Dictionary = entry
			_button("%s   (%d/%d)" % [e.host_name if e.host_name != "" else "Lobby", e.count, e.max],
				func(): SteamLobby.join(e.lobby_id))
	_button("Back", func(): _goto(Screen.MAIN))


func _render_room() -> void:
	_title("Lobby")
	var taken := SteamLobby.seats_taken()
	for member in SteamLobby.members:
		var m: Dictionary = member
		var mine: bool = m.steam_id == SteamManager.steam_id
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)

		var who := Label.new()
		who.custom_minimum_size = Vector2(190, 0)
		who.text = "%s%s%s" % [m.name, "  (host)" if m.is_host else "", "  ✓" if m.ready else ""]
		row.add_child(who)

		for s in SteamLobby.MAX_PLAYERS:
			var seat_btn := Button.new()
			seat_btn.text = str(s + 1)
			seat_btn.toggle_mode = true
			seat_btn.button_pressed = m.seat == s
			seat_btn.disabled = not mine or (taken.has(s) and taken[s] != m.steam_id)
			if mine:
				seat_btn.pressed.connect(func(): SteamLobby.set_my_seat(s))
			row.add_child(seat_btn)

		if mine:
			var ready_btn := CheckButton.new()
			ready_btn.text = "Ready"
			ready_btn.button_pressed = m.ready
			ready_btn.toggled.connect(func(on): SteamLobby.set_my_ready(on))
			row.add_child(ready_btn)

		_box.add_child(row)

	_box.add_child(HSeparator.new())
	_button("Invite Friends…", func(): SteamLobby.invite_friend())

	if SteamLobby.is_host:
		var start := _button("Start Game", func(): SteamLobby.start_game())
		start.disabled = not _all_set()
		if not _all_set():
			_label("Everyone needs a distinct seat and Ready before start.")
	else:
		_label("Waiting for the host to start…")

	_button("Leave Lobby", func(): SteamLobby.leave())


func _all_set() -> bool:
	if SteamLobby.members.is_empty():
		return false
	var seats := {}
	for m in SteamLobby.members:
		if m.seat < 0 or seats.has(m.seat) or not m.ready:
			return false
		seats[m.seat] = true
	return true


# --- signal handlers --------------------------------------------------

func _on_lobby_entered(_as_host: bool) -> void:
	_goto(Screen.ROOM)


func _on_lobby_exited() -> void:
	if _screen == Screen.ROOM:
		_goto(Screen.BROWSE)


func _on_game_starting(seat_map: Dictionary, names: Dictionary) -> void:
	NetSession.configure_multiplayer(seat_map, names, SteamManager.steam_id)
	get_tree().change_scene_to_file("res://game.tscn")


func _open_browse() -> void:
	_goto(Screen.BROWSE)
	SteamLobby.refresh_browse()


func _start_singleplayer() -> void:
	NetSession.configure_singleplayer()
	get_tree().change_scene_to_file("res://game.tscn")


# --- tiny UI helpers ------------------------------------------------

func _goto(s: int) -> void:
	_screen = s
	_render()


func _title(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 40)
	_box.add_child(l)


func _label(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_box.add_child(l)


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 44)
	b.pressed.connect(cb)
	_box.add_child(b)
	return b


func _flash(msg: String) -> void:
	_toast.text = msg
	_toast_until = Time.get_ticks_msec() / 1000.0 + 4.0
