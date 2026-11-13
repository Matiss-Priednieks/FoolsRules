extends Node
## Autoload: Steam lobby lifecycle - host, browse, join, seats and ready-ups, start, back to the room.

const MAX_PLAYERS := DurakGame.MAX_PLAYERS  # 24
const DEFAULT_PLAYERS := 4

# Steam ELobbyType 2 == public. Lobbies are always Public so an invite code
# (below) can resolve for someone who isn't a Steam friend.
const _LOBBY_PUBLIC := 2

# String keys used with Steam's setLobbyData/setLobbyMemberData. Lobby-data is
# host-written and shared; member-data each player writes for themselves.
const GAME_TAG := "game"
const HOST_NAME := "host_name"
const LOBBY_STATE := "state"     # "setup" or "starting"
const SEATMAP := "seatmap"       # JSON { "<steam_id>": <seat> }, written on start
const LISTED := "listed"         # "0" keeps a lobby out of the browser
const PLAYERS := "players"       # seat count for this lobby's game (host-written)
const SEAT := "seat"             # "-1" unset, else "0".. (num_players - 1)
const READY := "ready"
const PLAYER_NAME := "name"

signal lobby_entered(as_host: bool)
signal lobby_exited()
signal lobby_error(msg: String)
signal members_updated()
signal browse_updated()
## seat_map: { steam_id:int -> seat:int }, names: { steam_id:int -> String }
signal game_starting(seat_map: Dictionary, names: Dictionary, game_seed: int, player_count: int)
## We lost the lobby itself mid-match (game.gd bails to the menu on it).
signal disconnected_unexpectedly(reason: String)

var in_lobby := false
var is_host := false
var lobby_id: int = 0
var members: Array[Dictionary] = []          # [{steam_id, name, seat, ready, is_host}]
var browse_results: Array[Dictionary] = []   # [{lobby_id, host_name, count, max}]

var player_count := DEFAULT_PLAYERS  # this lobby's seat count (host sets it, clients read it)

var _steam: Object = null
var _starting := false
var _done_seed := 0 # the match we just came back from - its stale "starting" data mustn't restart it
var _started_seed := 0 # the match we've already gone into - lobby updates mustn't start it twice
var _pending_listed := true
var _pending_count := DEFAULT_PLAYERS


func _ready() -> void:
	if not SteamManager.available:
		return
	_steam = SteamManager.api()
	_steam.connect("lobby_created", _on_lobby_created)
	_steam.connect("lobby_joined", _on_lobby_joined)
	_steam.connect("lobby_match_list", _on_lobby_match_list)
	_steam.connect("lobby_chat_update", _on_lobby_chat_update)
	_steam.connect("lobby_data_update", _on_lobby_data_update)
	_steam.connect("join_requested", _on_join_requested)
	Net.host_changed.connect(_on_host_changed)
	Net.message.connect(_on_net_message)

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
func host(listed := true, seats := DEFAULT_PLAYERS) -> void:
	if not _guard():
		return
	if in_lobby:
		leave()
	_starting = false
	_pending_listed = listed
	_pending_count = clampi(seats, 2, MAX_PLAYERS)
	_steam.createLobby(_LOBBY_PUBLIC, _pending_count)


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
	Net.stop()
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


## Host only. Freeze the seat assignment, pick one shared DurakGame seed so
## every peer deals identically, and tell every member to load the board.
func start_game() -> void:
	if not is_host or not in_lobby:
		return
	var seat_map := _resolve_seats()
	var seats_wire := {}
	for steam_id in seat_map:
		seats_wire[str(steam_id)] = seat_map[steam_id]
	var payload := {seed = randi_range(1, 2000000000), seats = seats_wire}
	_steam.setLobbyData(lobby_id, SEATMAP, JSON.stringify(payload))
	_steam.setLobbyData(lobby_id, LOBBY_STATE, "starting")
	# stays joinable: a player who drops can rejoin (the browser already hides
	# started lobbies, and anyone not in the seat map is turned away)
	_maybe_start()  # host may not get its own lobby_data_update


## After a match: everyone's back in the room. The host reopens the lobby for
## another round (same people, seats kept, ready-ups cleared).
func back_to_room() -> void:
	if not in_lobby:
		return
	_starting = false
	_done_seed = NetSession.seed
	_steam.setLobbyMemberData(lobby_id, READY, "0")
	if is_host:
		_steam.setLobbyData(lobby_id, SEATMAP, "")
		_steam.setLobbyData(lobby_id, LOBBY_STATE, "setup")
	_rebuild_members()
	members_updated.emit()


## Host only: tell a member to leave (Steam has no kick of its own).
func kick(steam_id: int) -> void:
	if is_host and in_lobby and steam_id != SteamManager.steam_id:
		Net.send_to(steam_id, {t = "kick"})


func _on_net_message(sender: int, msg: Dictionary) -> void:
	if str(msg.get("t", "")) == "kick" and in_lobby and sender == int(_steam.getLobbyOwner(lobby_id)):
		leave()
		lobby_error.emit("The host removed you from the lobby.")


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
	player_count = _pending_count
	_steam.setLobbyData(lobby_id, GAME_TAG, "durak")
	_steam.setLobbyData(lobby_id, HOST_NAME, SteamManager.persona_name)
	_steam.setLobbyData(lobby_id, LOBBY_STATE, "setup")
	_steam.setLobbyData(lobby_id, LISTED, "1" if _pending_listed else "0")
	_steam.setLobbyData(lobby_id, PLAYERS, str(player_count))
	_steam.setLobbyMemberData(lobby_id, PLAYER_NAME, SteamManager.persona_name)
	_steam.setLobbyMemberData(lobby_id, SEAT, "0")   # host takes seat 0
	_steam.setLobbyMemberData(lobby_id, READY, "0")
	Net.use_steam(lobby_id)
	_rebuild_members()
	lobby_entered.emit(true)
	members_updated.emit()


func _on_lobby_joined(this_lobby: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:  # 1 == k_EChatRoomEnterResponseSuccess
		lobby_error.emit("couldn't join lobby (%d)" % response)
		return
	# createLobby fires lobby_joined for the creator too - _on_lobby_created has
	# already set everything up, and re-writing member-data would reset our
	# seat. So: if we're already in this lobby, we made it.
	if in_lobby and lobby_id == this_lobby:
		return
	lobby_id = this_lobby
	in_lobby = true
	is_host = int(_steam.getLobbyOwner(lobby_id)) == SteamManager.steam_id
	_read_player_count()
	_steam.setLobbyMemberData(lobby_id, PLAYER_NAME, SteamManager.persona_name)
	_steam.setLobbyMemberData(lobby_id, SEAT, "-1")
	_steam.setLobbyMemberData(lobby_id, READY, "0")
	Net.use_steam(lobby_id)
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
	if not is_host:
		_read_player_count()
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


## Clients read the host-written seat count out of lobby-data. Falls back to the
## current value if the key isn't set yet (an older host, or a race on join).
func _read_player_count() -> void:
	var raw := str(_steam.getLobbyData(lobby_id, PLAYERS))
	if raw != "":
		player_count = clampi(int(raw), 2, MAX_PLAYERS)


## Lobby chat needs no connection: everyone in the lobby can be reached.
func get_connected_peer_count() -> int:
	return maxi(members.size() - 1, 0)


func all_peers_connected() -> bool:
	return in_lobby


## Steam picked a new owner (the host left): follow it.
func _on_host_changed(new_host: int) -> void:
	is_host = new_host == SteamManager.steam_id
	_rebuild_members()
	members_updated.emit()


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
		if m.seat >= 0 and m.seat < player_count and not used.has(m.seat):
			seat_map[m.steam_id] = m.seat
			used[m.seat] = true
	for m in ordered:
		if seat_map.has(m.steam_id):
			continue
		for s in player_count:
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
	if not (parsed is Dictionary) or not parsed.has("seats"):
		return
	var game_seed := int(parsed.get("seed", 0))
	if game_seed == _done_seed or game_seed == _started_seed:
		return # the round we just finished, or the one we're already in
	var seat_map := {}
	var names := {}
	for key in parsed.seats:
		seat_map[int(key)] = int(parsed.seats[key])
	if not seat_map.has(SteamManager.steam_id):
		lobby_error.emit("That game has already started.")
		leave()
		return
	_starting = true
	_started_seed = game_seed
	for m in members:
		names[m.steam_id] = m.name
	game_starting.emit(seat_map, names, game_seed, player_count)
