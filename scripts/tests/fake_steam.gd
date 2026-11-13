extends Node
## Test double for the GodotSteam singleton: just the lobby part of Steam,
## talking to fake_steam_server.gd over localhost instead of Steam's servers.
## Launch the game with `-- --fake-steam=<n>` and SteamManager hands this to
## everything instead of the real thing, as account n. Same method names,
## same signals, same callback timing (fired from run_callbacks()), so
## steam_lobby.gd and net.gd run unchanged - several instances on one machine
## can then host, join, chat, leave and take over lobbies like real players.
## Not a Steam emulator: no overlay, stats or friends (those are no-ops).

signal lobby_created(result: int, lobby_id: int)
signal lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int)
signal lobby_match_list(lobbies: Array)
signal lobby_chat_update(lobby_id: int, changed_id: int, making_change_id: int, chat_state: int)
signal lobby_data_update(success: int, lobby_id: int, member_id: int)
signal lobby_message(lobby_id: int, user: int, message: String, chat_type: int)
signal join_requested(lobby_id: int, friend_id: int)
signal user_stats_received(game: int, result: int, user: int)
signal overlay_toggled(active: bool)

const PORT := 27999
const BASE_ID := 76561190000000000

var _id := 0
var _name := ""
var _tcp := StreamPeerTCP.new()
var _buf := ""
var _lobbies := {} # id -> {owner, members: [], data: {}, mdata: {member: {}}, max}
var _queue: Array = [] # requests made before the socket finished connecting


func _init(index: int) -> void:
	_id = BASE_ID + index
	_name = "Tester %d" % index
	_tcp.connect_to_host("127.0.0.1", PORT)


func steamInitEx(_app: int, _embed: bool) -> Dictionary:
	for _i in 200: # up to ~2s for the local server
		_tcp.poll()
		if _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			_send({op = "hello", id = str(_id), name = _name})
			return {status = 0, verbal = "fake steam"}
		OS.delay_msec(10)
	return {status = 1, verbal = "fake steam server not running (scripts/tests/fake_steam_server.gd)"}


func getSteamID() -> int: return _id
func getPersonaName() -> String: return _name
func getFriendPersonaName(id: int) -> String: return "Tester %d" % (id - BASE_ID)
func run_callbacks() -> void: _poll()


# ---- lobbies
func createLobby(_type: int, max_members: int) -> void: _send({op = "create", max = max_members})
## (every ID on the wire is text: JSON numbers can't hold a Steam ID exactly)
func joinLobby(lobby_id: int) -> void: _send({op = "join", lobby = str(lobby_id)})
func leaveLobby(lobby_id: int) -> void:
	_send({op = "leave", lobby = str(lobby_id)})
	_lobbies.erase(lobby_id)
func requestLobbyList() -> void: _send({op = "list"})
func addRequestLobbyListStringFilter(_k: String, _v: String, _cmp: int) -> void: pass
func addRequestLobbyListDistanceFilter(_d: int) -> void: pass
func setLobbyJoinable(_lobby: int, _joinable: bool) -> bool: return true

func getLobbyOwner(lobby_id: int) -> int:
	return int(_lobbies.get(lobby_id, {}).get("owner", 0))

func getNumLobbyMembers(lobby_id: int) -> int:
	return _lobbies.get(lobby_id, {}).get("members", []).size()

func getLobbyMemberByIndex(lobby_id: int, i: int) -> int:
	var members: Array = _lobbies.get(lobby_id, {}).get("members", [])
	return int(members[i]) if i < members.size() else 0

func getLobbyMemberLimit(lobby_id: int) -> int:
	return int(_lobbies.get(lobby_id, {}).get("max", 0))

func getLobbyData(lobby_id: int, key: String) -> String:
	return str(_lobbies.get(lobby_id, {}).get("data", {}).get(key, ""))

func setLobbyData(lobby_id: int, key: String, value: String) -> bool:
	if getLobbyOwner(lobby_id) != _id:
		return false
	_lobbies[lobby_id].data[key] = value # visible to us at once, like Steam
	_send({op = "data", lobby = str(lobby_id), k = key, v = value})
	return true

func getLobbyMemberData(lobby_id: int, member: int, key: String) -> String:
	return str(_lobbies.get(lobby_id, {}).get("mdata", {}).get(str(member), {}).get(key, ""))

func setLobbyMemberData(lobby_id: int, key: String, value: String) -> void:
	if _lobbies.has(lobby_id):
		_lobbies[lobby_id].mdata.get_or_add(str(_id), {})[key] = value
	_send({op = "mdata", lobby = str(lobby_id), k = key, v = value})

func sendLobbyChatMsg(lobby_id: int, text: String) -> bool:
	_send({op = "chat", lobby = str(lobby_id), text = text})
	return true


# ---- everything else Steam does: harmless no-ops
func initRelayNetworkAccess() -> void: pass
func requestUserStats(_id_: int) -> void: pass
func activateGameOverlayInviteDialog(_lobby: int) -> void: pass
func activateGameOverlay(_to: String) -> void: pass
func isOverlayEnabled() -> bool: return false
func getAchievement(_n: String) -> Dictionary: return {ret = false, achieved = false}
func setAchievement(_n: String) -> bool: return false
func clearAchievement(_n: String) -> bool: return false
func getStatInt(_n: String) -> int: return 0
func setStatInt(_n: String, _v: int) -> bool: return false
func storeStats() -> bool: return false
func resetAllStats(_a: bool) -> bool: return false
func steamShutdown() -> void: _tcp.disconnect_from_host()


# ---- wire
func _send(msg: Dictionary) -> void:
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_queue.append(msg)
		return
	for queued in _queue:
		_tcp.put_data((JSON.stringify(queued) + "\n").to_utf8_buffer())
	_queue.clear()
	_tcp.put_data((JSON.stringify(msg) + "\n").to_utf8_buffer())


func _poll() -> void:
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var n := _tcp.get_available_bytes()
	if n > 0:
		_buf += _tcp.get_utf8_string(n)
	while "\n" in _buf:
		var line := _buf.get_slice("\n", 0)
		_buf = _buf.substr(line.length() + 1)
		var ev: Variant = JSON.parse_string(line)
		if ev is Dictionary:
			_on_event(ev)


func _on_event(ev: Dictionary) -> void:
	var lobby := int(str(ev.get("lobby", "0")))
	if ev.has("state"): # every event carries the lobby's latest state first
		var st: Dictionary = ev.state
		if st.is_empty():
			_lobbies.erase(lobby)
		else:
			_lobbies[lobby] = {owner = int(str(st.owner)), members = st.members.map(func(m): return int(str(m))),
				data = st.data, mdata = st.mdata, max = int(st.max)}
	match str(ev.get("ev", "")):
		"created": lobby_created.emit(int(ev.result), lobby)
		"joined": lobby_joined.emit(lobby, 0, false, int(ev.response))
		"list": lobby_match_list.emit(ev.lobbies.map(func(l): return int(str(l))))
		"chat_update": lobby_chat_update.emit(lobby, int(str(ev.changed)), int(str(ev.changed)), int(ev.chat_state))
		"data_update": lobby_data_update.emit(1, lobby, int(str(ev.member)))
		"message": lobby_message.emit(lobby, int(str(ev.user)), str(ev.text), 1)
