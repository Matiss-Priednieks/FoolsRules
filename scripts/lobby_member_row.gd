extends HBoxContainer
## One row in the lobby ROOM screen's member list: name, a seat picker, a Ready
## toggle. A fresh instance is built per member on every render (see menu.gd), so
## setup() connects signals unconditionally - there's never a stale connection to
## guard against. The seat picker is an OptionButton so it scales from 2 up to
## DurakGame.MAX_PLAYERS seats without the row growing unboundedly wide.

signal seat_picked(seat: int)
signal ready_toggled(on: bool)

@onready var _name_label: Label = $NameLabel
@onready var _seat_pick: OptionButton = $SeatPick
@onready var _ready_check: CheckButton = $ReadyCheck


## `member`: one entry of SteamLobby.members. `mine`: this row is the local
## player's own, so its controls are interactive. `taken`: SteamLobby.seats_taken().
## `seats`: how many seats this lobby's game has (SteamLobby.player_count).
func setup(member: Dictionary, mine: bool, taken: Dictionary, seats: int) -> void:
	_name_label.text = "%s%s%s" % [
		member.name, "  (host)" if member.is_host else "", "  ✓" if member.ready else ""]

	_seat_pick.clear()
	_seat_pick.add_item("no seat", -1)
	_seat_pick.set_item_id(0, -1)
	var selected := 0
	for i in seats:
		var idx := _seat_pick.item_count
		_seat_pick.add_item("Seat %d" % (i + 1), i)
		var others_have: bool = taken.has(i) and taken[i] != member.steam_id
		_seat_pick.set_item_disabled(idx, others_have)
		if member.seat == i:
			selected = idx
	_seat_pick.selected = selected
	_seat_pick.disabled = not mine
	if mine:
		_seat_pick.item_selected.connect(func(idx: int): seat_picked.emit(_seat_pick.get_item_id(idx)))

	_ready_check.visible = mine
	_ready_check.button_pressed = member.ready
	if mine:
		_ready_check.toggled.connect(ready_toggled.emit)
