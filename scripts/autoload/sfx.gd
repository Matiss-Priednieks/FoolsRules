extends Node
## Autoload: every sound effect in the game goes through here - one voice pool, shared by the menu, the Card Archive, the scene swipe and the table.

const VOICES := 16
const HOVER_GAP := 0.06 ## seconds - hovers closer than this are dropped, so a fast sweep doesn't machine-gun

var enabled := true
var volume_db := -6.0

var _deal: Array[AudioStream] = []
var _fan: Array[AudioStream] = []
var _fan_long: Array[AudioStream] = []
var _click: Array[AudioStream] = []
var _stamp: Array[AudioStream] = []
var _fire: Array[AudioStream] = []
var _voices: Array[AudioStreamPlayer] = []
var _next := 0
var _last_hover := 0.0


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		enabled = false
		return
	for i in range(1, 10):
		_deal.append(load("res://assets/audio/sfx/deal_%d.mp3" % i))
	_fan = [load("res://assets/audio/sfx/card_fan_1.mp3"), load("res://assets/audio/sfx/card_fan_2.mp3")]
	_fan_long = [load("res://assets/audio/sfx/card_fan_3.mp3")]
	_click = [load("res://assets/audio/sfx/penclick.mp3")]
	_stamp = [load("res://assets/audio/sfx/stamp_sfx.mp3")]
	_fire = [load("res://assets/audio/sfx/Fire_sfx.mp3")]
	for _v in VOICES:
		var voice := AudioStreamPlayer.new()
		add_child(voice)
		_voices.append(voice)
	process_mode = Node.PROCESS_MODE_ALWAYS
	# every button clicks - including ones already built before this was ready
	get_tree().node_added.connect(_on_node_added)
	_hook_all(get_tree().root)


func deal(trim_db := 0.0) -> void:
	_play(_deal, trim_db, 1.0)


func hover() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_hover < HOVER_GAP:
		return
	_last_hover = now
	_play(_deal, -14.0, randf_range(1.15, 1.25))


func click(trim_db := 0.0) -> void:
	_play(_click, trim_db, 1.0)


## the CLEARED stamp landing
func stamp() -> void:
	_play(_stamp, 0.0, 1.0)


## cards going up in flames (Flame Hazard, Purge)
func fire() -> void:
	_play(_fire, 0.0, 1.0)


func fan(trim_db := 2.0) -> void:
	_play(_fan, trim_db, 1.0)


func fan_long(trim_db := 0.0) -> void:
	_play(_fan_long, trim_db, 1.0)


## `count` deal clicks spread out by `stagger` seconds, so a six-card refill
## rattles out instead of cracking as one sound. Fire-and-forget.
func deal_burst(count: int, stagger := 0.05) -> void:
	if not enabled or count <= 0:
		return
	var n := mini(count, 12)
	for i in n:
		deal()
		if i < n - 1:
			await get_tree().create_timer(stagger + randf() * 0.02).timeout


func _play(streams: Array[AudioStream], trim_db: float, pitch: float) -> void:
	if not enabled or streams.is_empty():
		return
	var voice := _voices[_next]
	_next = (_next + 1) % _voices.size()
	voice.stream = streams[randi() % streams.size()]
	voice.volume_db = volume_db + trim_db
	voice.pitch_scale = pitch * randf_range(0.94, 1.06)
	voice.play()


func _hook_all(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children(true):
		_hook_all(child)


func _on_node_added(node: Node) -> void:
	if node is BaseButton and not node.has_meta("sfx_hooked"):
		node.set_meta("sfx_hooked", true)
		(node as BaseButton).pressed.connect(click)
