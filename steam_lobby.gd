extends Node
## Autoload. Steam lobby lifecycle for multiplayer Durak.
##
## Milestone 1 = lobby plumbing only: host / browse / join / leave, a member
## list with per-seat + ready state carried in Steam lobby member-data, and a
## host-triggered "start" that hands every member the same seat map. No gameplay
## action sync yet - that's the next milestone.
##
## Everything gates on SteamManager.available; with no Steam the methods emit
## `lobby_error` and change nothing. All Steam calls go through the `_steam`
## singleton fetched at runtime (never the bare `Steam` identifier) so this file
## still parses without the GodotSteam extension.

const MAX_PLAYERS := 4

# Steam ELobbyType: 0 private, 1 friends-only, 2 public, 3 invisible.
const _LOBBY_FRIENDS := 1
const _LOBBY_PUBLIC := 2

# String keys used with Steam's setLobbyData/setLobbyMemberData. Lobby-data is
# host-written and shared; member-data each player writes for themselves.
const GAME_TAG := "game"
const HOST_NAME := "host_name"
const LOBBY_STATE := "state"     # "setup" or "starting"
const SEATMAP := "seatmap"       # JSON { "<steam_id>": <seat> }, written on start
const LISTED := "listed"         # "0" keeps a lobby out of the browser
const SEAT := "seat"             # "-1" unset, else "0".."3"
const READY := "ready"
const PLAYER_NAME := "name"

signal lobby_entered(as_host: bool)
signal lobby_exited()
signal lobby_error(msg: String)
signal members_updated()
signal browse_updated()
## seat_map: { steam_id:int -> seat:int }, names: { steam_id:int -> String }
signal game_starting(seat_map: Dictionary, names: Dictionary)

var in_lobby := false
var is_host := false
var lobby_id: int = 0
var members: Array[Dictionary] = []          # [{steam_id, name, seat, ready, is_host}]
var browse_results: Array[Dictionary] = []   # [{lobby_id, host_name, count, max}]

var _steam: Object = null
var _peer: MultiplayerPeer = null
var _starting := false
var _pending_listed := true


func _ready() -> void:
	if not SteamManager.available:
		return
	_steam = Engine.get_singleton("Steam")
	_steam.connect("lobby_created", _on_lobby_created)
	_steam.connect("lobby_joined", _on_lobby_joined)
	_steam.connect("lobby_match_list", _on_lobby_match_list)
	_steam.connect("lobby_chat_update", _on_lobby_chat_update)
	_steam.connect("lobby_data_update", _on_lobby_data_update)
	_steam.connect("join_requested", _on_join_requested)

	# Launched by accepting a Steam invite from outside the game:
	# Steam appends "+connect_lobby <id>" to the command line.
	var args := OS.get_cmdline_args()
	var idx := args.find("+connect_lobby")
	if idx != -1 and idx + 1 < args.size():
		var pending := int(args[idx + 1])
		if pending != 0:
			join.call_deferred(pending)


# --- public API -----------------------------------------------------------

## `listed` false = the lobby stays out of the in-game browser; it can then only
## be joined via its invite code (get_invite_code) or a Steam overlay invite.
## The lobby is Public either way so a code works for non-friends.
func host(listed := true) -> void:
	if not _guard():
		return
	if in_lobby:
		leave()
	_starting = false
	_pending_listed = listed
	_steam.createLobby(_LOBBY_PUBLIC, MAX_PLAYERS)


func join(target: int) -> void:
	if not _guard():
		return
	if in_lobby:
		leave()
	_starting = false
	_steam.joinLobby(target)


func leave() -> void:
	if in_lobby and _steam != null:
		_steam.leaveLobby(lobby_id)
	if multiplayer.multiplayer_peer == _peer:
		multiplayer.multiplayer_peer = null
	_peer = null
	in_lobby = false
	is_host = false
	lobby_id = 0
	_starting = false
	members.clear()
	lobby_exited.emit()


func refresh_browse() -> void:
	if not _guard():
		return
	if _steam.has_method("addRequestLobbyListStringFilter"):
		_steam.addRequestLobbyListStringFilter(GAME_TAG, "durak", 0)  # 0 == equal
	if _steam.has_method("addRequestLobbyListDistanceFilter"):
		_steam.addRequestLobbyListDistanceFilter(3)  # 3 == worldwide
	_steam.requestLobbyList()


func set_my_seat(seat: int) -> void:
	if in_lobby:
		_steam.setLobbyMemberData(lobby_id, SEAT, str(seat))


func set_my_ready(is_ready: bool) -> void:
	if in_lobby:
		_steam.setLobbyMemberData(lobby_id, READY, "1" if is_ready else "0")


func invite_friend() -> void:
	if in_lobby:
		_steam.activateGameOverlayInviteDialog(lobby_id)


## Copy-paste code that resolves straight to this lobby, no friendship needed.
## It is just the lobby's Steam ID in hex, grouped in fours for readability.
func get_invite_code() -> String:
	if not in_lobby or lobby_id == 0:
		return ""
	var hex := String.num_int64(lobby_id, 16).to_upper()
	var out := ""
	for i in hex.length():
		if i > 0 and (hex.length() - i) % 4 == 0:
			out += "-"
		out += hex[i]
	return out


func join_by_code(code: String) -> void:
	if not _guard():
		return
	var digits := ""
	for ch in code.to_upper():
		if ch in "0123456789ABCDEF":
			digits += ch
	if digits.is_empty():
		lobby_error.emit("Enter an invite code")
		return
	var id := digits.hex_to_int()
	if id <= 0:
		lobby_error.emit("That invite code isn't valid")
		return
	join(id)


## Host only. Freeze the seat assignment and tell every member to load the board.
func start_game() -> void:
	if not is_host or not in_lobby:
		return
	var seat_map := _resolve_seats()
	var wire := {}
	for steam_id in seat_map:
		wire[str(steam_id)] = seat_map[steam_id]
	_steam.setLobbyData(lobby_id, SEATMAP, JSON.stringify(wire))
	_steam.setLobbyData(lobby_id, LOBBY_STATE, "starting")
	if _steam.has_method("setLobbyJoinable"):
		_steam.setLobbyJoinable(lobby_id, false)
	_maybe_start()  # host may not get its own lobby_data_update


func seats_taken() -> Dictionary:
	var taken := {}  # seat -> steam_id
	for m in members:
		if m.seat >= 0:
			taken[m.seat] = m.steam_id
	return taken


# --- Steam callbacks ----------------------------------------------------

func _on_lobby_created(result: int, new_lobby_id: int) -> void:
	if result != 1:  # 1 == k_EResultOK
		lobby_error.emit("couldn't create lobby (%d)" % result)
		return
	lobby_id = new_lobby_id
	in_lobby = true
	is_host = true
	_steam.setLobbyData(lobby_id, GAME_TAG, "durak")
	_steam.setLobbyData(lobby_id, HOST_NAME, SteamManager.persona_name)
	_steam.setLobbyData(lobby_id, LOBBY_STATE, "setup")
	_steam.setLobbyData(lobby_id, LISTED, "1" if _pending_listed else "0")
	_steam.setLobbyMemberData(lobby_id, PLAYER_NAME, SteamManager.persona_name)
	_steam.setLobbyMemberData(lobby_id, SEAT, "0")   # host takes seat 0
	_steam.setLobbyMemberData(lobby_id, READY, "0")
	_start_peer(true)
	_rebuild_members()
	lobby_entered.emit(true)
	members_updated.emit()


func _on_lobby_joined(this_lobby: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:  # 1 == k_EChatRoomEnterResponseSuccess
		lobby_error.emit("couldn't join lobby (%d)" % response)
		return
	lobby_id = this_lobby
	in_lobby = true
	is_host = int(_steam.getLobbyOwner(lobby_id)) == SteamManager.steam_id
	_steam.setLobbyMemberData(lobby_id, PLAYER_NAME, SteamManager.persona_name)
	_steam.setLobbyMemberData(lobby_id, SEAT, "-1")
	_steam.setLobbyMemberData(lobby_id, READY, "0")
	_start_peer(is_host)
	_rebuild_members()
	lobby_entered.emit(is_host)
	members_updated.emit()
	_maybe_start()  # in case the host already flipped state while we were joining


func _on_lobby_match_list(lobbies: Array) -> void:
	browse_results.clear()
	for entry in lobbies:
		var id := int(entry)
		if str(_steam.getLobbyData(id, GAME_TAG)) != "durak":
			continue
		if str(_steam.getLobbyData(id, LOBBY_STATE)) == "starting":
			continue
		if str(_steam.getLobbyData(id, LISTED)) == "0":
			continue  # code / invite only
		browse_results.append({
			lobby_id = id,
			host_name = str(_steam.getLobbyData(id, HOST_NAME)),
			count = int(_steam.getNumLobbyMembers(id)),
			max = int(_steam.getLobbyMemberLimit(id)),
		})
	browse_updated.emit()


func _on_lobby_chat_update(updated_lobby: int, _changed_id: int, _by_id: int, _state: int) -> void:
	if updated_lobby != lobby_id:
		return
	_rebuild_members()
	members_updated.emit()


func _on_lobby_data_update(_success: int, updated_lobby: int, _member_id: int) -> void:
	if updated_lobby != lobby_id:
		return
	_rebuild_members()
	members_updated.emit()
	if str(_steam.getLobbyData(lobby_id, LOBBY_STATE)) == "starting":
		_maybe_start()


func _on_join_requested(requested_lobby: int, _friend_id: int) -> void:
	join(requested_lobby)


# --- internals --------------------------------------------------------

func _guard() -> bool:
	if not SteamManager.available or _steam == null:
		lobby_error.emit("Steam not available")
		return false
	return true


func _start_peer(as_host: bool) -> void:
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		return
	_peer = ClassDB.instantiate("SteamMultiplayerPeer")
	var err := OK
	if as_host:
		err = _peer.host_with_lobby(lobby_id) if _peer.has_method("host_with_lobby") else _peer.create_host(0)
	else:
		err = _peer.connect_to_lobby(lobby_id) if _peer.has_method("connect_to_lobby") else _peer.create_client(int(_steam.getLobbyOwner(lobby_id)), 0)
	if err != OK:
		push_warning("[Lobby] SteamMultiplayerPeer setup failed (%s); lobby-data channel still works." % err)
		_peer = null
		return
	multiplayer.multiplayer_peer = _peer


func _rebuild_members() -> void:
	members.clear()
	if not in_lobby:
		return
	var owner_id := int(_steam.getLobbyOwner(lobby_id))
	var count := int(_steam.getNumLobbyMembers(lobby_id))
	for i in count:
		var sid := int(_steam.getLobbyMemberByIndex(lobby_id, i))
		var name_str := str(_steam.getLobbyMemberData(lobby_id, sid, PLAYER_NAME))
		if name_str == "":
			name_str = str(_steam.getFriendPersonaName(sid))
		var seat_str := str(_steam.getLobbyMemberData(lobby_id, sid, SEAT))
		var ready_str := str(_steam.getLobbyMemberData(lobby_id, sid, READY))
		members.append({
			steam_id = sid,
			name = name_str,
			seat = int(seat_str) if seat_str != "" else -1,
			ready = ready_str == "1",
			is_host = sid == owner_id,
		})


## Give every member a seat: keep valid distinct choices, fill the rest by lowest
## free index (host first). Returns { steam_id -> seat }.
func _resolve_seats() -> Dictionary:
	var seat_map := {}
	var used := {}
	var ordered := members.duplicate()
	ordered.sort_custom(func(a, b): return a.is_host and not b.is_host)
	for m in ordered:
		if m.seat >= 0 and m.seat < MAX_PLAYERS and not used.has(m.seat):
			seat_map[m.steam_id] = m.seat
			used[m.seat] = true
	for m in ordered:
		if seat_map.has(m.steam_id):
			continue
		for s in MAX_PLAYERS:
			if not used.has(s):
				seat_map[m.steam_id] = s
				used[s] = true
				break
	return seat_map


func _maybe_start() -> void:
	if _starting or not in_lobby:
		return
	var raw := str(_steam.getLobbyData(lobby_id, SEATMAP))
	if raw == "":
		return
	var parsed: Variant = JSON.parse_string(raw)
	if not (parsed is Dictionary):
		return
	_starting = true
	var seat_map := {}
	var names := {}
	for key in parsed:
		var sid := int(key)
		seat_map[sid] = int(parsed[key])
	for m in members:
		names[m.steam_id] = m.name
	game_starting.emit(seat_map, names)
