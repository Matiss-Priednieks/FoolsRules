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
## The RPC connection to the host died (or never truly formed) after the match
## already started - a client-only signal (MultiplayerAPI.server_disconnected
## never fires on the host). game.gd listens for this to bail out gracefully
## instead of sitting frozen with no feedback.
signal disconnected_unexpectedly(reason: String)

var in_lobby := false
var is_host := false
var lobby_id: int = 0
var members: Array[Dictionary] = []          # [{steam_id, name, seat, ready, is_host}]
var browse_results: Array[Dictionary] = []   # [{lobby_id, host_name, count, max}]

var player_count := DEFAULT_PLAYERS  # this lobby's seat count (host sets it, clients read it)

var _steam: Object = null
var _peer: MultiplayerPeer = null
var _starting := false
var _pending_listed := true
var _pending_count := DEFAULT_PLAYERS


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
	_teardown_peer()
	in_lobby = false
	is_host = false
	lobby_id = 0
	_starting = false
	members.clear()
	lobby_exited.emit()


## Fully release the multiplayer peer: close its Steam listen socket (else the
## next host/join in this process fails with "socket already in use", err 20)
## and drop the signal handlers so they don't stack across lobby cycles.
func _teardown_peer() -> void:
	for pair in [
		[&"peer_connected", _on_peer_connected],
		[&"peer_disconnected", _on_peer_disconnected],
		[&"connection_failed", _on_connection_failed],
		[&"server_disconnected", _on_server_disconnected],
	]:
		if multiplayer.is_connected(pair[0], pair[1]):
			multiplayer.disconnect(pair[0], pair[1])
	# Detaching the peer from the MultiplayerAPI drops the last strong ref (it's
	# RefCounted) and lets its destructor close the Steam listen socket. Calling
	# _peer.close() explicitly here crashed GodotSteam v4.22 on the second host,
	# so don't - release it and let _start_peer's back-off give Steam time to
	# actually free the socket before the next host attempt.
	if multiplayer.has_multiplayer_peer():
		multiplayer.multiplayer_peer = null
	_peer = null


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
	if _steam.has_method("setLobbyJoinable"):
		_steam.setLobbyJoinable(lobby_id, false)
	_maybe_start()  # host may not get its own lobby_data_update


func seats_taken() -> Dictionary:
	var taken := {}  # seat -> steam_id
	for m in members:
		if m.seat >= 0:
			taken[m.seat] = m.steam_id
	return taken


## The Steam ID behind a Godot multiplayer peer id, for RPC sender -> seat
## lookups. 0 if there's no active peer or the id is unknown.
func steam_id_for_peer(peer_id: int) -> int:
	if _peer == null or not _peer.has_method("get_steam_id_for_peer_id"):
		return 0
	return int(_peer.get_steam_id_for_peer_id(peer_id))


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
	_start_peer(true)
	_rebuild_members()
	lobby_entered.emit(true)
	members_updated.emit()


func _on_lobby_joined(this_lobby: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != 1:  # 1 == k_EChatRoomEnterResponseSuccess
		lobby_error.emit("couldn't join lobby (%d)" % response)
		return
	# createLobby fires lobby_joined for the creator too - _on_lobby_created has
	# already set our peer + member-data up. Re-running _start_peer() here fails
	# to make a second listen socket and breaks the host's networking; re-writing
	# member-data resets our seat. So: if we're already in this lobby, we made it.
	if in_lobby and lobby_id == this_lobby:
		return
	lobby_id = this_lobby
	in_lobby = true
	is_host = int(_steam.getLobbyOwner(lobby_id)) == SteamManager.steam_id
	_read_player_count()
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


## Bring up the SteamMultiplayerPeer for this lobby. Opening the Steam Datagram
## Relay listen socket can transiently fail - the relay backend is still coming
## online, Steam's servers are mid-restart, or the previous lobby's socket hasn't
## finished releasing - so this retries with a growing back-off before giving up.
func _start_peer(as_host: bool) -> void:
	if not ClassDB.class_exists("SteamMultiplayerPeer"):
		return

	# First try is near-immediate; later tries wait longer to ride out a relay
	# blip or a slow socket release.
	var backoff := [0.05, 0.75, 1.5, 3.0]
	for attempt in backoff.size():
		if not in_lobby:
			return
		_teardown_peer()  # also clears anything a failed previous attempt left
		await get_tree().create_timer(backoff[attempt]).timeout
		if not in_lobby:
			return

		_peer = ClassDB.instantiate("SteamMultiplayerPeer")
		# Direct P2P between two real machines routinely fails to punch through
		# NAT/firewalls even though the peer object is created fine - the
		# connection just never completes and every later RPC errors as "not
		# connected". Steam's relay network (SDR) is the fallback; it has to be
		# on before the connection attempt starts.
		if _peer.has_method("set_server_relay"):
			_peer.set_server_relay(true)
		var err := OK
		if as_host:
			err = _peer.host_with_lobby(lobby_id) if _peer.has_method("host_with_lobby") else _peer.create_host(0)
		else:
			err = _peer.connect_to_lobby(lobby_id) if _peer.has_method("connect_to_lobby") else _peer.create_client(int(_steam.getLobbyOwner(lobby_id)), 0)

		if err == OK:
			multiplayer.multiplayer_peer = _peer
			print("[Lobby] peer started (%s) on attempt %d, status=%d"
				% ["host" if as_host else "client", attempt + 1, _peer.get_connection_status()])
			multiplayer.peer_connected.connect(_on_peer_connected)
			multiplayer.peer_disconnected.connect(_on_peer_disconnected)
			multiplayer.connection_failed.connect(_on_connection_failed)
			multiplayer.server_disconnected.connect(_on_server_disconnected)
			return

		push_warning("[Lobby] peer setup attempt %d/%d failed (%s)"
			% [attempt + 1, backoff.size(), err])
		_peer = null  # drop the ref; next loop's _teardown_peer + wait lets it release

	lobby_error.emit("Steam networking didn't come up (it may be having a wobble - Steam server restarts do this). Leave the lobby and try again in a minute.")


func _on_peer_connected(id: int) -> void:
	print("[Lobby] peer_connected: %d" % id)
	members_updated.emit() # room UI re-checks all_peers_connected() for the Start button

func _on_peer_disconnected(id: int) -> void:
	print("[Lobby] peer_disconnected: %d" % id)
	members_updated.emit()

func _on_connection_failed() -> void:
	print("[Lobby] connection_failed")
	lobby_error.emit("Couldn't reach the host. Leave and rejoin.")


func get_connected_peer_count() -> int:
	return multiplayer.get_peers().size() if multiplayer.has_multiplayer_peer() else 0


## Every other lobby member is a live RPC peer. The host must not be allowed to
## Start until this is true, or clients load the board on a dead channel.
func all_peers_connected() -> bool:
	if not in_lobby or _peer == null:
		return false
	return get_connected_peer_count() >= maxi(members.size() - 1, 0)


func _on_server_disconnected() -> void:
	push_warning("[Lobby] lost connection to the host")
	var was_in_lobby := in_lobby
	leave()
	if was_in_lobby:
		disconnected_unexpectedly.emit("Lost connection to the host.")


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
	_starting = true
	var seat_map := {}
	var names := {}
	for key in parsed.seats:
		seat_map[int(key)] = int(parsed.seats[key])
	for m in members:
		names[m.steam_id] = m.name
	game_starting.emit(seat_map, names, int(parsed.get("seed", 0)), player_count)
