extends Control
## Main menu + multiplayer lobby room. Static layout lives in menu.tscn;
## this just wires it up and rebuilds the two lists that vary at runtime
## (BrowsePanel/ResultsBox, RoomPanel/MembersBox via lobby_member_row.tscn).
## Three screens: MAIN -> BROWSE -> ROOM.

enum Screen { MAIN, BROWSE, ROOM }

const LAN_PORT := 8471
const LobbyMemberRow := preload("res://scenes/lobby_member_row.tscn")

@onready var _toast: Label = $Toast
@onready var _main_panel: Control = $MainPanel
@onready var _browse_panel: Control = $BrowsePanel
@onready var _room_panel: Control = $RoomPanel

@onready var _singleplayer_button: Button = $MainPanel/MainBox/SingleplayerButton
@onready var _multiplayer_button: Button = $MainPanel/MainBox/MultiplayerButton
@onready var _quit_button: Button = $MainPanel/MainBox/QuitButton

@onready var _list_publicly_check: CheckButton = $BrowsePanel/BrowseBox/ListPubliclyCheck
@onready var _host_button: Button = $BrowsePanel/BrowseBox/HostButton
@onready var _code_field: LineEdit = $BrowsePanel/BrowseBox/CodeRow/CodeField
@onready var _join_by_code_button: Button = $BrowsePanel/BrowseBox/CodeRow/JoinByCodeButton
@onready var _refresh_button: Button = $BrowsePanel/BrowseBox/RefreshButton
@onready var _results_box: VBoxContainer = $BrowsePanel/BrowseBox/ResultsBox
@onready var _back_button: Button = $BrowsePanel/BrowseBox/BackButton

@onready var _members_box: VBoxContainer = $RoomPanel/RoomBox/MembersBox
@onready var _invite_code_row: Control = $RoomPanel/RoomBox/InviteCodeRow
@onready var _invite_code_label: Label = $RoomPanel/RoomBox/InviteCodeRow/InviteCodeLabel
@onready var _copy_button: Button = $RoomPanel/RoomBox/InviteCodeRow/CopyButton
@onready var _invite_friends_button: Button = $RoomPanel/RoomBox/InviteFriendsButton
@onready var _start_button: Button = $RoomPanel/RoomBox/StartButton
@onready var _hint_label: Label = $RoomPanel/RoomBox/HintLabel
@onready var _leave_button: Button = $RoomPanel/RoomBox/LeaveButton

var _screen := Screen.MAIN
var _toast_until := 0.0
var _current_invite_code := ""
var _host_seats := 4                  ## seat count the host will create the lobby with
var _seat_value_label: Label = null


## No-Steam local test transport: run one instance with `-- --lan-host` and a
## second with `-- --lan-join` (add `=<ip>` for a different machine; defaults
## to 127.0.0.1) to play a real two-peer match without Steam or a friend.
## Works from `--headless` too, so this same path is scriptable for testing.
func _ready() -> void:
	var args: Array = Array(OS.get_cmdline_user_args())
	if "--lan-host" in args:
		_start_lan_test(true, "")
		return
	var join_args := args.filter(func(a): return str(a).begins_with("--lan-join"))
	if not join_args.is_empty():
		var join_arg := str(join_args[0])
		var addr: String = join_arg.get_slice("=", 1) if "=" in join_arg else "127.0.0.1"
		_start_lan_test(false, addr)
		return

	if DisplayServer.get_name() == "headless":
		_start_singleplayer.call_deferred() # headless run == the self-play smoke test
		return

	_singleplayer_button.pressed.connect(_start_singleplayer)
	_multiplayer_button.pressed.connect(_open_browse)
	_quit_button.pressed.connect(get_tree().quit)
	if not SteamManager.available:
		_multiplayer_button.disabled = true
		_multiplayer_button.text = "Multiplayer  (Steam not running)"

	_build_seat_stepper()
	_host_button.pressed.connect(func(): SteamLobby.host(_list_publicly_check.button_pressed, _host_seats))
	_join_by_code_button.pressed.connect(func(): SteamLobby.join_by_code(_code_field.text))
	_refresh_button.pressed.connect(SteamLobby.refresh_browse)
	_back_button.pressed.connect(_goto.bind(Screen.MAIN))

	_copy_button.pressed.connect(func(): _copy_code(_current_invite_code))
	_invite_friends_button.pressed.connect(SteamLobby.invite_friend)
	_start_button.pressed.connect(SteamLobby.start_game)
	_leave_button.pressed.connect(SteamLobby.leave)

	SteamLobby.lobby_entered.connect(_on_lobby_entered)
	SteamLobby.lobby_exited.connect(_on_lobby_exited)
	SteamLobby.lobby_error.connect(_flash)
	SteamLobby.members_updated.connect(_refresh_room)
	SteamLobby.browse_updated.connect(_refresh_browse)
	SteamLobby.game_starting.connect(_on_game_starting)

	_goto(Screen.MAIN)
	if NetSession.pending_message != "":
		_flash(NetSession.pending_message)
		NetSession.pending_message = ""


func _process(_delta: float) -> void:
	if _toast == null:
		return
	if _toast.text != "" and Time.get_ticks_msec() / 1000.0 > _toast_until:
		_toast.text = ""


# --- screen switching -------------------------------------------------

func _goto(screen: int) -> void:
	_screen = screen
	_main_panel.visible = screen == Screen.MAIN
	_browse_panel.visible = screen == Screen.BROWSE
	_room_panel.visible = screen == Screen.ROOM
	if screen == Screen.BROWSE:
		_refresh_browse()
	elif screen == Screen.ROOM:
		_refresh_room()


func _open_browse() -> void:
	_goto(Screen.BROWSE)
	SteamLobby.refresh_browse()


# --- host seat count ------------------------------------------------

## A small "- N +" stepper built in code and slotted above Host Game, so the
## host picks the table size (2..DurakGame.MAX_PLAYERS) before creating a lobby.
## Kept procedural to leave menu.tscn (theme WIP) untouched.
func _build_seat_stepper() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	var caption := Label.new()
	caption.text = "Players:"
	row.add_child(caption)

	var minus := Button.new()
	minus.text = "  −  "
	minus.pressed.connect(func(): _nudge_seats(-1))
	row.add_child(minus)

	_seat_value_label = Label.new()
	_seat_value_label.custom_minimum_size = Vector2(40, 0)
	_seat_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(_seat_value_label)

	var plus := Button.new()
	plus.text = "  +  "
	plus.pressed.connect(func(): _nudge_seats(1))
	row.add_child(plus)

	var box := _host_button.get_parent()
	box.add_child(row)
	box.move_child(row, _host_button.get_index())
	_update_seat_label()


func _nudge_seats(delta: int) -> void:
	_host_seats = clampi(_host_seats + delta, 2, SteamLobby.MAX_PLAYERS)
	_update_seat_label()


func _update_seat_label() -> void:
	if _seat_value_label != null:
		_seat_value_label.text = str(_host_seats)


# --- dynamic content ---------------------------------------------------

func _refresh_browse() -> void:
	if _screen != Screen.BROWSE:
		return
	for child in _results_box.get_children():
		child.queue_free()
	if SteamLobby.browse_results.is_empty():
		var l := Label.new()
		l.text = "No public lobbies. Host one, join by code, or Refresh."
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_results_box.add_child(l)
	else:
		for entry in SteamLobby.browse_results:
			var e: Dictionary = entry
			var b := Button.new()
			b.custom_minimum_size = Vector2(0, 44)
			b.text = "%s   (%d/%d)" % [e.host_name if e.host_name != "" else "Lobby", e.count, e.max]
			b.pressed.connect(func(): SteamLobby.join(e.lobby_id))
			_results_box.add_child(b)


func _refresh_room() -> void:
	if _screen != Screen.ROOM:
		return
	for child in _members_box.get_children():
		child.queue_free()
	var taken := SteamLobby.seats_taken()
	for member in SteamLobby.members:
		var m: Dictionary = member
		var row := LobbyMemberRow.instantiate()
		_members_box.add_child(row)
		row.setup(m, m.steam_id == SteamManager.steam_id, taken, SteamLobby.player_count)
		row.seat_picked.connect(SteamLobby.set_my_seat)
		row.ready_toggled.connect(SteamLobby.set_my_ready)

	_current_invite_code = SteamLobby.get_invite_code()
	_invite_code_row.visible = _current_invite_code != ""
	_invite_code_label.text = "Invite code:  %s" % _current_invite_code

	var connected := SteamLobby.all_peers_connected()
	var others := maxi(SteamLobby.members.size() - 1, 0)
	_start_button.visible = SteamLobby.is_host
	_start_button.disabled = not _all_set() or not connected
	if SteamLobby.is_host:
		if not _all_set():
			_hint_label.text = "Everyone needs a distinct seat and Ready before start."
		elif not connected:
			_hint_label.text = "Connecting to players… (%d/%d)" % [SteamLobby.get_connected_peer_count(), others]
		else:
			_hint_label.text = ""
	else:
		_hint_label.text = "Connecting…" if not connected else "Waiting for the host to start…"


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


func _on_game_starting(seat_map: Dictionary, names: Dictionary, game_seed: int, player_count: int) -> void:
	NetSession.configure_multiplayer(seat_map, names, SteamManager.steam_id, game_seed, player_count)
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _copy_code(code: String) -> void:
	DisplayServer.clipboard_set(code)
	_flash("invite code copied")


func _start_singleplayer() -> void:
	NetSession.configure_singleplayer()
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _start_lan_test(is_host: bool, address: String) -> void:
	NetSession.configure_lan_test(0 if is_host else 1)
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(LAN_PORT, 1) if is_host else peer.create_client(address, LAN_PORT)
	if err != OK:
		push_warning("[lan] %s failed: %s" % ["create_server" if is_host else "create_client", err])
		return
	multiplayer.multiplayer_peer = peer
	if is_host:
		print("[lan] hosting on port %d - waiting for the other instance" % LAN_PORT)
		multiplayer.peer_connected.connect(_on_lan_guest_connected)
	else:
		print("[lan] connecting to %s:%d" % [address, LAN_PORT])
		multiplayer.connected_to_server.connect(_on_lan_connected)
		multiplayer.connection_failed.connect(func(): push_warning("[lan] connection failed"))


func _on_lan_guest_connected(id: int) -> void:
	NetSession.seat_peer_id[1] = id
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _on_lan_connected() -> void:
	get_tree().change_scene_to_file("res://scenes/game.tscn")


func _flash(msg: String) -> void:
	_toast.text = msg
	_toast_until = Time.get_ticks_msec() / 1000.0 + 4.0
