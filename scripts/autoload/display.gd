extends Node
## Autoload: window mode setting (Windowed / Borderless / Fullscreen), saved to
## user://settings.cfg next to the music settings. The game always renders at
## 1920x1080 and project stretch (canvas_items + keep) scales it to whatever
## the window is, letterboxing off-16:9 shapes, so every mode/size just works.

const SETTINGS_PATH := "user://settings.cfg"
enum Mode { WINDOWED, BORDERLESS, FULLSCREEN }
const MODE_NAMES := ["Windowed", "Borderless", "Fullscreen"]

var mode: Mode = Mode.BORDERLESS
## Full = CRT + dither on (the intended look); Light = both off, for weaker
## phones / battery. Cards keep their own wear either way.
var effects_full := true


## Running on a phone/tablet build (Android/iOS).
static func mobile() -> bool:
	return OS.has_feature("mobile")


## Touch controls (long-press for info, no hover): on phones, or on desktop
## with `-- --touch` to try them out with the mouse.
static func touch() -> bool:
	return mobile() or "--touch" in OS.get_cmdline_user_args()


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		mode = cfg.get_value("display", "mode", mode)
		effects_full = cfg.get_value("display", "effects_full", effects_full)
	_apply_effects.call_deferred() # CRT/Dither autoloads aren't in the tree yet
	if mobile():
		return # the OS owns the window on a phone
	_apply()
	get_window().min_size = Vector2i(960, 540)


## Android's back button/gesture acts like Esc everywhere (pause menu, close
## the archive close-up, back out of a menu page) - see quit_on_go_back.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		var back := InputEventAction.new()
		back.action = &"ui_cancel"
		back.pressed = true
		Input.parse_input_event(back)


func set_effects(full: bool) -> void:
	effects_full = full
	_apply_effects()
	_save("effects_full", full)


func effects_name() -> String:
	return "Full" if effects_full else "Light"


func _apply_effects() -> void:
	CRT.enabled = effects_full
	Dither.visible = effects_full


func _save(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH) # keep the other sections
	cfg.set_value("display", key, value)
	cfg.save(SETTINGS_PATH)


func set_mode(m: Mode) -> void:
	mode = m
	_apply()
	_save("mode", mode)


func cycle() -> void:
	set_mode(((mode + 1) % Mode.size()) as Mode)


func mode_name() -> String:
	return MODE_NAMES[mode]


func _apply() -> void:
	match mode:
		Mode.FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		Mode.BORDERLESS: # Godot's "fullscreen" is the borderless, alt-tab-friendly one
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		Mode.WINDOWED:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			# a 16:9 window that fits the screen with room for title bar / taskbar
			var screen := DisplayServer.screen_get_usable_rect()
			var w := mini(1600, int(screen.size.x * 0.85))
			var size := Vector2i(w, w * 9 / 16)
			DisplayServer.window_set_size(size)
			DisplayServer.window_set_position(screen.position + (screen.size - size) / 2)
