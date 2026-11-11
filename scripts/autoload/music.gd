extends AudioStreamPlayer
## Autoload: the soundtrack. Lives above the scene tree so it keeps looping
## seamlessly across menu <-> game scene changes. Owns the music settings
## (on/off + volume) and persists them to user://settings.cfg.

const SETTINGS_PATH := "user://settings.cfg"

var enabled := true
var volume := 0.5 ## linear 0..1 (slider value)


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		enabled = cfg.get_value("music", "enabled", enabled)
		volume = cfg.get_value("music", "volume", volume)
	var track: AudioStreamMP3 = load("res://assets/audio/music/music_duraks.mp3")
	track.loop = true
	stream = track
	process_mode = Node.PROCESS_MODE_ALWAYS
	_apply()
	play()


func set_enabled(on: bool) -> void:
	enabled = on
	_apply()
	_save()


func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 1.0)
	enabled = true # dragging the slider is a clear "I want music"
	_apply()
	_save()


func _apply() -> void:
	volume_db = linear_to_db(volume) - 6.0 # -6 trim: sits under the SFX at full slider
	stream_paused = not enabled # pause, not stop, so toggling back resumes mid-track


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # keep any other sections
	cfg.set_value("music", "enabled", enabled)
	cfg.set_value("music", "volume", volume)
	cfg.save(SETTINGS_PATH)
