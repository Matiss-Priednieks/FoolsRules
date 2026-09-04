extends Node
## Autoload. Steam-agnostic handoff between the menu and the board.
##
## The menu fills this in before switching to game.tscn; game.gd reads it in
## _ready(). Singleplayer sets `active = false` and game.gd behaves exactly as
## before. Nothing here knows about Steam, so the board stays decoupled from the
## networking layer.

var active := false                  ## true = launched from a multiplayer lobby
var local_seat := 0                  ## which DurakGame seat this client controls
var seat_is_bot: Array[bool] = [false, false, false, false]  ## per-seat: bot fills it
var player_names: Array[String] = ["", "", "", ""]           ## display name per seat ("" = bot)


func configure_singleplayer() -> void:
	active = false
	local_seat = 0
	seat_is_bot = [false, true, true, true]
	player_names = ["You", "", "", ""]


## seat_map: { steam_id:int -> seat:int }, names: { steam_id:int -> String }.
func configure_multiplayer(seat_map: Dictionary, names: Dictionary, my_steam_id: int) -> void:
	active = true
	seat_is_bot = [true, true, true, true]
	player_names = ["", "", "", ""]
	for steam_id in seat_map:
		var seat: int = seat_map[steam_id]
		if seat < 0 or seat > 3:
			continue
		seat_is_bot[seat] = false
		player_names[seat] = str(names.get(steam_id, "P%d" % seat))
		if steam_id == my_steam_id:
			local_seat = seat
