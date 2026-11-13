extends SceneTree
## The other half of fake_steam.gd: Steam's lobby service, played locally.
##   godot --headless --path . --script res://scripts/tests/fake_steam_server.gd
## Keeps lobbies (owner, members, lobby data, per-member data), relays lobby
## chat to every member (the sender too, like Steam), and when the owner
## leaves hands the lobby to the next member, like Steam does. A game
## instance that disconnects counts as leaving. Quits on its own after
## `-- --fake-steam-idle=<s>` seconds without any connected game (default 30).
## Every ID on the wire is text: JSON numbers can't hold a Steam ID exactly.

const PORT := 27999

var _server := TCPServer.new()
var _peers: Array = [] # [{tcp, buf, id}]
var _lobbies := {} # lobby id (String) -> {owner, members: [], data: {}, mdata: {}, max}
var _next_lobby := 109775240000000000
var _idle_limit := 30.0
var _idle := 0.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--fake-steam-idle="):
			_idle_limit = float(str(a).get_slice("=", 1))
	var err := _server.listen(PORT, "127.0.0.1")
	print("[fake steam] %s on %d" % ["listening" if err == OK else "can't listen (%d)" % err, PORT])
	if err != OK:
		quit(1)


func _process(delta: float) -> bool:
	while _server.is_connection_available():
		_peers.append({tcp = _server.take_connection(), buf = "", id = ""})
	for peer in _peers.duplicate():
		var tcp: StreamPeerTCP = peer.tcp
		tcp.poll()
		if tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_drop(peer)
			continue
		var n := tcp.get_available_bytes()
		if n > 0:
			peer.buf += tcp.get_utf8_string(n)
		while "\n" in peer.buf:
			var line: String = peer.buf.get_slice("\n", 0)
			peer.buf = peer.buf.substr(line.length() + 1)
			var msg: Variant = JSON.parse_string(line)
			if msg is Dictionary:
				_handle(peer, msg)
	_idle = 0.0 if not _peers.is_empty() else _idle + delta
	if _idle > _idle_limit:
		print("[fake steam] idle, shutting down")
		return true
	return false


func _handle(peer: Dictionary, msg: Dictionary) -> void:
	var me: String = peer.id
	var lid := str(msg.get("lobby", ""))
	match str(msg.get("op", "")):
		"hello":
			peer.id = str(msg.id)
		"create":
			_next_lobby += 1
			lid = str(_next_lobby)
			_lobbies[lid] = {owner = me, members = [me], data = {}, mdata = {me: {}}, max = int(msg.get("max", 4))}
			print("[fake steam] %s created lobby %s" % [me, lid])
			_tell(me, lid, {ev = "created", result = 1})
			_tell(me, lid, {ev = "joined", response = 1})
		"join":
			if not _lobbies.has(lid):
				_tell(me, lid, {ev = "joined", response = 2}) # k_EChatRoomEnterResponseDoesntExist
				return
			var lobby: Dictionary = _lobbies[lid]
			if me not in lobby.members:
				if lobby.members.size() >= lobby.max:
					_tell(me, lid, {ev = "joined", response = 4}) # full
					return
				lobby.members.append(me)
				lobby.mdata[me] = {}
			print("[fake steam] %s joined %s (%d in)" % [me, lid, lobby.members.size()])
			_tell(me, lid, {ev = "joined", response = 1})
			_tell_all(lid, {ev = "chat_update", changed = me, chat_state = 1})
		"leave":
			_leave(me, lid, 2)
		"data":
			if _lobbies.has(lid) and _lobbies[lid].owner == me:
				_lobbies[lid].data[str(msg.k)] = str(msg.v)
				_tell_all(lid, {ev = "data_update", member = lid})
		"mdata":
			if _lobbies.has(lid) and me in _lobbies[lid].members:
				_lobbies[lid].mdata[me][str(msg.k)] = str(msg.v)
				_tell_all(lid, {ev = "data_update", member = me})
		"chat":
			if _lobbies.has(lid) and me in _lobbies[lid].members:
				_tell_all(lid, {ev = "message", user = me, text = str(msg.text)})
		"list":
			_tell(me, "", {ev = "list", lobbies = _lobbies.keys()})


## `how`: 2 = left, 4 = disconnected (the game instance went away).
func _leave(member: String, lid: String, how: int) -> void:
	if not _lobbies.has(lid) or member not in _lobbies[lid].members:
		return
	var lobby: Dictionary = _lobbies[lid]
	lobby.members.erase(member)
	lobby.mdata.erase(member)
	if lobby.members.is_empty():
		_lobbies.erase(lid)
		print("[fake steam] lobby %s closed" % lid)
		return
	if lobby.owner == member:
		lobby.owner = lobby.members[0] # Steam hands the lobby on
		print("[fake steam] %s left %s - %s owns it now" % [member, lid, lobby.owner])
	else:
		print("[fake steam] %s left %s" % [member, lid])
	_tell_all(lid, {ev = "chat_update", changed = member, chat_state = how})


func _drop(peer: Dictionary) -> void:
	_peers.erase(peer)
	for lid in _lobbies.keys():
		_leave(peer.id, lid, 4)


func _state(lid: String) -> Dictionary:
	if not _lobbies.has(lid):
		return {}
	var l: Dictionary = _lobbies[lid]
	return {owner = l.owner, members = l.members, data = l.data, mdata = l.mdata, max = l.max}


func _tell(member: String, lid: String, ev: Dictionary) -> void:
	ev.lobby = lid
	ev.state = _state(lid)
	for peer in _peers:
		if peer.id == member:
			peer.tcp.put_data((JSON.stringify(ev) + "\n").to_utf8_buffer())


func _tell_all(lid: String, ev: Dictionary) -> void:
	for member in _lobbies.get(lid, {}).get("members", []):
		_tell(member, lid, ev.duplicate())
