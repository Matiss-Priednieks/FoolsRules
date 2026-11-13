extends Node
## Autoload. The one pipe every multiplayer message goes through.
##
## Messages are plain Dictionaries with a "t" (type) key. game.gd never knows
## how they travel; there are two carriers:
##   STEAM - the Steam lobby's own chat channel (sendLobbyChatMsg). It goes
##           through Steam's servers to every member: no direct connections,
##           no handshake, no listen sockets, so nothing to time out, leak or
##           get blocked by a router. If you're in the lobby, you can talk.
##           (Replaced SteamMultiplayerPeer, which never released its socket
##           and could hang on "connecting" forever.)
##   LAN   - an ENet test transport between local instances (menu.gd's
##           --lan-host / --lan-join). Messages go to this autoload's own
##           RPC, and /root/Net exists in every instance from launch, so a
##           message can't be lost to a scene that hasn't loaded yet.
##
## A sender is identified by a "key": a Steam ID (STEAM) or an ENet peer id
## (LAN). NetSession maps keys to seats.

enum Mode { OFF, STEAM, LAN }

signal message(sender: int, msg: Dictionary)
## A member left the lobby / an ENet peer dropped (key = who).
signal member_left(key: int)
## The lobby's owner changed (STEAM: the host left and Steam picked another).
signal host_changed(new_host_key: int)

const _CHUNK := 3000 # bytes per lobby chat message (Steam's cap is 4096)
const LAN_HOST_KEY := 1 # the ENet server is always peer 1

var mode := Mode.OFF
var _steam: Object = null
var _lobby := 0
var _host_key := 0
var _chunks := {} # "<sender>:<id>" -> {n, parts: {i: text}}
var _chunk_seq := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if SteamManager.available:
		_steam = SteamManager.api()
		_steam.connect("lobby_message", _on_lobby_message)
		_steam.connect("lobby_chat_update", _on_lobby_chat_update)
		_steam.connect("lobby_data_update", _on_lobby_data_update)
	multiplayer.peer_disconnected.connect(func(id: int):
		if mode == Mode.LAN:
			member_left.emit(id))


func use_steam(lobby_id: int) -> void:
	mode = Mode.STEAM
	_lobby = lobby_id
	_host_key = int(_steam.getLobbyOwner(lobby_id))


func use_lan() -> void:
	mode = Mode.LAN
	_host_key = LAN_HOST_KEY


func stop() -> void:
	mode = Mode.OFF
	_lobby = 0
	_chunks.clear()


## This machine's own key.
func my_key() -> int:
	if mode == Mode.STEAM:
		return SteamManager.steam_id
	if mode == Mode.LAN and multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return 0


func host_key() -> int:
	return _host_key


func is_host() -> bool:
	return mode != Mode.OFF and my_key() == _host_key


## Can we reach the host right now? STEAM: we're in the lobby and so is it.
func host_reachable() -> bool:
	match mode:
		Mode.STEAM:
			return _lobby != 0 and SteamLobby.in_lobby
		Mode.LAN:
			var p := multiplayer.multiplayer_peer
			return p != null and not (p is OfflineMultiplayerPeer) \
				and p.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
				and (is_host() or LAN_HOST_KEY in multiplayer.get_peers())
	return false


func send_to_host(msg: Dictionary) -> void:
	send_to(_host_key, msg)


## To everyone else (the host's broadcast).
func broadcast(msg: Dictionary) -> void:
	send_to(0, msg)


## `to` = a key, or 0 for everyone but me.
func send_to(to: int, msg: Dictionary) -> void:
	match mode:
		Mode.STEAM:
			# Steam IDs are bigger than a JSON number holds exactly (floats are
			# exact to ~9e15, IDs are ~7.6e16), so the address travels as text
			var body := JSON.stringify({to = str(to), m = msg})
			if body.length() <= _CHUNK:
				_steam.sendLobbyChatMsg(_lobby, body)
				return
			# a long message (a rejoin's move log) goes in numbered pieces
			_chunk_seq += 1
			var n := ceili(body.length() / float(_CHUNK))
			for i in n:
				_steam.sendLobbyChatMsg(_lobby, JSON.stringify({
					to = str(to), c = _chunk_seq, i = i, n = n, d = body.substr(i * _CHUNK, _CHUNK)}))
		Mode.LAN:
			if to == 0:
				_lan_msg.rpc(msg)
			elif to == my_key():
				message.emit(to, msg)
			else:
				_lan_msg.rpc_id(to, msg)


@rpc("any_peer", "call_remote", "reliable")
func _lan_msg(msg: Dictionary) -> void:
	message.emit(multiplayer.get_remote_sender_id(), msg)


func _on_lobby_message(lobby_id: int, user: int, text: String, _chat_type: int) -> void:
	if mode != Mode.STEAM or lobby_id != _lobby or user == my_key():
		return # Steam echoes our own messages back to us
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return
	var to := str(data.get("to", "0"))
	if to != "0" and to != str(my_key()):
		return # addressed to someone else
	if data.has("c"): # a piece of a long message
		var key := "%d:%d" % [user, int(data.c)]
		var entry: Dictionary = _chunks.get_or_add(key, {n = int(data.n), parts = {}})
		entry.parts[int(data.i)] = str(data.d)
		if entry.parts.size() < entry.n:
			return
		var whole := ""
		for i in entry.n:
			whole += entry.parts[i]
		_chunks.erase(key)
		data = JSON.parse_string(whole)
		if not (data is Dictionary):
			return
	if data.has("m") and data.m is Dictionary:
		message.emit(user, _ints(data.m))


## JSON hands every number back as a float; the game wants ints (seats, ranks).
func _ints(v: Variant) -> Variant:
	if v is float and v == floorf(v):
		return int(v)
	if v is Dictionary:
		var out := {}
		for k in v:
			out[k] = _ints(v[k])
		return out
	if v is Array:
		return v.map(_ints)
	return v


func _on_lobby_chat_update(lobby_id: int, changed_id: int, _making_change: int, chat_state: int) -> void:
	if mode != Mode.STEAM or lobby_id != _lobby:
		return
	# EChatMemberStateChange: 1 entered; 2 left, 4 disconnected, 8 kicked, 16 banned
	if chat_state & (2 | 4 | 8 | 16):
		member_left.emit(changed_id)
	_check_owner()


func _on_lobby_data_update(_success: int, lobby_id: int, _member: int) -> void:
	if mode == Mode.STEAM and lobby_id == _lobby:
		_check_owner()


func _check_owner() -> void:
	var owner := int(_steam.getLobbyOwner(_lobby))
	if owner != 0 and owner != _host_key:
		_host_key = owner
		host_changed.emit(owner)
