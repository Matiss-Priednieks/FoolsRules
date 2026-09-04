extends HBoxContainer
## One row in the lobby ROOM screen's member list: name, four seat-pick
## buttons, a Ready toggle. A fresh instance is built per member on every
## render (see menu.gd), so setup() connects signals unconditionally - there's
## never a stale connection to guard against.

signal seat_picked(seat: int)
signal ready_toggled(on: bool)

@onready var _name_label: Label = $NameLabel
@onready var _seat_buttons: Array = [$Seat1, $Seat2, $Seat3, $Seat4]
@onready var _ready_check: CheckButton = $ReadyCheck


## `member`: one entry of SteamLobby.members. `mine`: this row is the local
## player's own, so its controls are interactive. `taken`: SteamLobby.seats_taken().
func setup(member: Dictionary, mine: bool, taken: Dictionary) -> void:
	_name_label.text = "%s%s%s" % [
		member.name, "  (host)" if member.is_host else "", "  ✓" if member.ready else ""]
	for i in _seat_buttons.size():
		var btn: Button = _seat_buttons[i]
		btn.button_pressed = member.seat == i
		btn.disabled = not mine or (taken.has(i) and taken[i] != member.steam_id)
		if mine:
			btn.pressed.connect(seat_picked.emit.bind(i))
	_ready_check.visible = mine
	_ready_check.button_pressed = member.ready
	if mine:
		_ready_check.toggled.connect(ready_toggled.emit)
