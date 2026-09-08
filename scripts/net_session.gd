extends Node
## Autoload. Steam-agnostic handoff between the menu and the board.
##
## The menu fills this in before switching to game.tscn; game.gd reads it in
## _ready(). Singleplayer sets `active = false` and game.gd behaves exactly as
## before. Nothing here knows about Steam, so the board stays decoupled from the
## networking layer.

var active := false                  ## true = launched from a multiplayer lobby
var num_players := 4                  ## seat count for this game (2..DurakGame.MAX_PLAYERS)
var local_seat := 0                  ## which DurakGame seat this client controls
var seat_is_bot: Array[bool] = []    ## per-seat: a bot fills it
var player_names: Array[String] = [] ## display name per seat ("" = bot)
var seat_steam_id: Array[int] = []   ## per-seat Steam ID, 0 = bot
var seat_peer_id: Array[int] = []    ## per-seat Godot multiplayer peer id (LAN test), 0 = bot
var seed := 0                        ## shared DurakGame seed so every peer deals identically
var pending_message := ""            ## one-shot notice for the menu to show after an unexpected return


func _reset(players: int) -> void:
	num_players = clampi(players, 2, DurakGame.MAX_PLAYERS)
	seat_is_bot = []
	player_names = []
	seat_steam_id = []
	seat_peer_id = []
	for _s in num_players:
		seat_is_bot.append(true)
		player_names.append("")
		seat_steam_id.append(0)
		seat_peer_id.append(0)


func configure_singleplayer() -> void:
	active = false
	seed = 0
	_reset(4)
	local_seat = 0
	seat_is_bot[0] = false
	player_names[0] = "You"


## seat_map: { steam_id:int -> seat:int }, names: { steam_id:int -> String }.
func configure_multiplayer(seat_map: Dictionary, names: Dictionary, my_steam_id: int, game_seed: int, players: int) -> void:
	active = true
	seed = game_seed
	_reset(players)
	for steam_id in seat_map:
		var seat: int = seat_map[steam_id]
		if seat < 0 or seat >= num_players:
			continue
		seat_is_bot[seat] = false
		seat_steam_id[seat] = steam_id
		player_names[seat] = str(names.get(steam_id, "P%d" % seat))
		if steam_id == my_steam_id:
			local_seat = seat


## No-Steam local test transport (see menu.gd's --lan-host / --lan-join): a
## fixed 2-player setup, host always seat 0, the one guest always seat 1.
func configure_lan_test(seat: int) -> void:
	active = true
	seed = 918273645 # fixed - both sides just need to match, not be unpredictable
	_reset(4)
	local_seat = seat
	seat_is_bot[0] = false
	seat_is_bot[1] = false
	player_names[0] = "Host"
	player_names[1] = "Guest"
	seat_peer_id[0] = 1 # ENet server is always peer id 1; index 1 fills in once the guest connects
