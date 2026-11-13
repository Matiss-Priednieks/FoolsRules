extends SceneTree
## One player in a fake-Steam lobby test (see fake_steam.gd). Runs the real
## lobby flow - host or join by invite code, pick a seat, ready up, start -
## then the real game, headless, auto-playing its own seat.
##   -- --fake-steam=<n> --role=host|join|rejoin --seat=<k> [--players=<p>]
##      --code-file=<path> [--lan-quit-after=<moves>] [--kick-seat=<k>]
##      [--churn=<times>]   leave and rejoin the lobby this many times first
##      [--stop-in-game]    quit as soon as our board is dealt (lobby stress)
## The host writes the invite code to --code-file; joiners read it from there.
## "rejoin" joins a lobby whose match is already running (a dropped player
## coming back in with the code).

var _args := {}


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--") and "=" in s:
			_args[s.get_slice("=", 0).substr(2)] = s.get_slice("=", 1)
	var lobby = root.get_node("SteamLobby")
	var launched := Time.get_ticks_msec()
	lobby.game_starting.connect(func(seat_map, names, game_seed, players):
		root.get_node("NetSession").configure_multiplayer(seat_map, names,
			root.get_node("SteamManager").steam_id, game_seed, players)
		print("[player] game starting, seat %d" % root.get_node("NetSession").local_seat)
		change_scene_to_file("res://scenes/game.tscn")
		if _args.has("stop-in-game"):
			_report_when_dealt(launched))
	lobby.lobby_error.connect(func(m): print("[player] lobby says: %s" % m))
	await create_timer(0.3).timeout
	if not root.get_node("SteamManager").available:
		print("[player] no (fake) steam - is fake_steam_server.gd running?")
		quit(1)
		return
	var role := str(_args.get("role", "join"))
	var seat := int(_args.get("seat", "0"))
	var code_file := str(_args.get("code-file", ""))
	if role == "host":
		lobby.host(false, int(_args.get("players", "3")))
		while not lobby.in_lobby:
			await process_frame
		var f := FileAccess.open(code_file, FileAccess.WRITE)
		f.store_string(lobby.get_invite_code())
		f.close()
		print("[player] hosting, code %s" % lobby.get_invite_code())
		lobby.set_my_ready(true)
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 30000:
			await create_timer(0.2).timeout
			if _args.has("kick-seat"):
				for m in lobby.members:
					if m.seat == int(_args["kick-seat"]) and not m.is_host:
						print("[player] kicking seat %d" % m.seat)
						lobby.kick(m.steam_id)
						_args.erase("kick-seat")
						break
			var want := int(_args.get("players", "3"))
			if lobby.members.size() == want and lobby.members.all(func(m): return m.ready and m.seat >= 0):
				print("[player] everyone's ready, starting")
				lobby.start_game()
				return
		print("[player] gave up waiting for players: %s" % [lobby.members])
		quit(1)
		return
	# join / rejoin: by invite code, like a friend would
	while not FileAccess.file_exists(code_file) or FileAccess.get_file_as_string(code_file) == "":
		await create_timer(0.1).timeout
	var code := FileAccess.get_file_as_string(code_file)
	for i in int(_args.get("churn", "0")): # can't make up their mind
		lobby.join_by_code(code)
		while not lobby.in_lobby:
			await process_frame
		if randf() < 0.5:
			lobby.set_my_seat(randi_range(0, int(_args.get("players", "3")) - 1))
		await create_timer(randf_range(0.1, 0.8)).timeout
		lobby.leave()
		await create_timer(randf_range(0.05, 0.5)).timeout
	lobby.join_by_code(code)
	while not lobby.in_lobby:
		await process_frame
	print("[player] joined with code %s" % code)
	if role == "join":
		lobby.set_my_seat(seat)
		# like a person: if someone else already has that seat, take a free one
		await create_timer(randf_range(0.2, 0.6)).timeout
		var taken: Dictionary = lobby.seats_taken()
		if taken.has(seat) and taken[seat] != root.get_node("SteamManager").steam_id:
			for s in lobby.player_count:
				if not taken.has(s):
					print("[player] seat %d taken, taking %d" % [seat, s])
					lobby.set_my_seat(s)
					break
		lobby.set_my_ready(true)
	# from here the lobby's game_starting takes us into the match
	var t1 := Time.get_ticks_msec()
	while lobby.in_lobby and Time.get_ticks_msec() - t1 < 60000:
		await create_timer(0.5).timeout
	if not lobby.in_lobby:
		print("[player] out of the lobby")
		quit()


## Lobby stress: report once our board exists (dealt or replayed), then go.
func _report_when_dealt(launched: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 30000:
		await process_frame
		var g = current_scene
		if g != null and g.get("game") != null and not g._busy:
			var ns = root.get_node("NetSession")
			if g._is_authority(): # the verdict: did it start with everyone who was meant to play?
				var bots: Array = []
				for seat in ns.num_players:
					if ns.seat_is_bot[seat]:
						bots.append(seat)
				print("[player] STARTED %s after %.1fs" % ["WITH EVERYONE" if bots.is_empty() else "MISSING seats %s" % [bots],
					(Time.get_ticks_msec() - launched) / 1000.0])
			else:
				print("[player] IN GAME seat %d after %.1fs" % [g.human_seat, (Time.get_ticks_msec() - launched) / 1000.0])
			await create_timer(1.0).timeout
			quit()
			return
	print("[player] NEVER GOT IN")
	quit(1)
