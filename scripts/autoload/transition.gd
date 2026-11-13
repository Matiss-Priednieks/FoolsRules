extends CanvasLayer
## Autoload: every scene change goes through Transition.change_scene(path), behind a soot swipe.

signal finished

const COVER_SECONDS := 0.4
const REVEAL_SECONDS := 0.6
const SMOOTH_FRAMES := 6 ## this many quick frames in a row = the new scene has settled
const SMOOTH_FRAME_MS := 25.0 ## a frame quicker than this counts as "smooth"
const LOADING_AFTER := 0.25 ## only show LOADING if the wait gets this long (no flash on fast PCs)
const SAFETY_TIMEOUT := 15.0 ## give up holding after this, whatever happens

var busy := false
var _rect: ColorRect
var _mat: ShaderMaterial
var _loading: Label


func _ready() -> void:
	layer = 127
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/transition.gdshader")
	_rect = ColorRect.new()
	_rect.material = _mat
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_STOP # swallow clicks mid-swipe
	_rect.visible = false
	add_child(_rect)
	_loading = Label.new()
	_loading.theme_type_variation = &"Heading"
	_loading.add_theme_color_override("font_color", Color(0.82, 0.76, 0.58))
	_loading.position = Vector2(1920 - 360, 1080 - 110)
	_loading.modulate.a = 0.0
	_loading.visible = false
	add_child(_loading)


func change_scene(path: String) -> void:
	if DisplayServer.get_name() == "headless":
		get_tree().change_scene_to_file(path)
		return
	if busy:
		return
	busy = true
	_rect.visible = true
	Sfx.fan_long()
	await _sweep(0.0, 1.0, COVER_SECONDS, Tween.EASE_IN)
	get_tree().change_scene_to_file(path)
	await _wait_until_ready()
	await _sweep(1.0, 2.0, REVEAL_SECONDS, Tween.EASE_OUT)
	_rect.visible = false
	busy = false
	finished.emit()


## Hold the cover until the new scene is ready and running smoothly, however
## long that takes on this machine; LOADING fades in if it's a noticeable wait.
func _wait_until_ready() -> void:
	var start := Time.get_ticks_msec()
	var smooth := 0
	var last := Time.get_ticks_usec()
	var showing := false
	while Time.get_ticks_msec() - start < SAFETY_TIMEOUT * 1000.0:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		smooth = smooth + 1 if (now - last) / 1000.0 < SMOOTH_FRAME_MS else 0
		last = now
		var scene := get_tree().current_scene
		var scene_ready: bool = scene != null and (not ("reveal_ready" in scene) or scene.reveal_ready)
		if scene_ready and smooth >= SMOOTH_FRAMES:
			break
		var waited := (Time.get_ticks_msec() - start) / 1000.0
		if waited > LOADING_AFTER:
			if not showing:
				showing = true
				_loading.visible = true
				create_tween().tween_property(_loading, "modulate:a", 1.0, 0.25)
			_loading.text = "LOADING" + ".".repeat(1 + int(waited * 3.0) % 3)
	if showing: # fade it fully out before the swipe moves on
		var tw := create_tween()
		tw.tween_property(_loading, "modulate:a", 0.0, 0.3)
		await tw.finished
		_loading.visible = false
	else:
		await get_tree().create_timer(0.1).timeout # a beat on full cover


func _sweep(from: float, to: float, seconds: float, ease: Tween.EaseType) -> void:
	_mat.set_shader_parameter("progress", from)
	var tw := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(ease)
	tw.tween_method(func(v: float): _mat.set_shader_parameter("progress", v), from, to, seconds)
	await tw.finished
