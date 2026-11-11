extends HBoxContainer
## One row in the lobby ROOM screen's member list: name, a seat picker, a Ready
## toggle. A fresh instance is built per member on every render (see menu.gd), so
## setup() connects signals unconditionally - there's never a stale connection to
## guard against. The seat picker is an OptionButton so it scales from 2 up to
## DurakGame.MAX_PLAYERS seats without the row growing unboundedly wide.
##
## Nodes are resolved inside setup() rather than via @onready: menu.gd calls
## setup() straight after add_child(), and _ready() (hence @onready) hasn't
## necessarily run yet when the caller is itself deep in a Steam callback.

signal seat_picked(seat: int)
signal ready_toggled(on: bool)


## `member`: one entry of SteamLobby.members. `mine`: this row is the local
## player's own, so its controls are interactive. `taken`: SteamLobby.seats_taken().
## `seats`: how many seats this lobby's game has (SteamLobby.player_count).
func setup(member: Dictionary, mine: bool, taken: Dictionary, seats: int) -> void:
	var name_label: Label = $NameLabel
	var seat_pick: OptionButton = $SeatPick
	var ready_check: CheckButton = $ReadyCheck

	name_label.text = "%s%s%s" % [
		member.name, "  (host)" if member.is_host else "", "  ✓" if member.ready else ""]

	seat_pick.clear()
	seat_pick.add_item("no seat", -1)
	seat_pick.set_item_id(0, -1)
	var selected := 0
	for i in seats:
		var idx := seat_pick.item_count
		seat_pick.add_item("Seat %d" % (i + 1), i)
		var others_have: bool = taken.has(i) and taken[i] != member.steam_id
		seat_pick.set_item_disabled(idx, others_have)
		if member.seat == i:
			selected = idx
	seat_pick.selected = selected
	seat_pick.disabled = not mine
	if mine:
		seat_pick.item_selected.connect(func(idx: int): seat_picked.emit(seat_pick.get_item_id(idx)))

	ready_check.visible = mine
	ready_check.button_pressed = member.ready
	if mine:
		ready_check.toggled.connect(ready_toggled.emit)
