extends CanvasLayer
## Autoload: the CRT screen effect over the whole game, plus the matching mouse warp.

@export var enabled := true:
	set(value):
		enabled = value
		if _rect:
			_rect.visible = value

var _rect: ColorRect
var _mat: ShaderMaterial


func _ready() -> void:
	layer = 128
	if DisplayServer.get_name() == "headless":
		enabled = false
		return
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/crt.gdshader")
	var params := {"curvature": 0.08, "bezel": 0.004, "scanline_amt": 0.15, "scanline_freq": 1080.0,
			"mask_amt": 0.1, "aberration": 0.6, "vignette_amt": 0.3, "flicker_amt": 0.02,
			"brightness": 1.1}
	for key in params:
		_mat.set_shader_parameter(key, params[key])
	_rect = ColorRect.new()
	_rect.material = _mat
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.visible = enabled
	add_child(_rect)


## True while the CRT is bending the picture (and so mouse input needs bending too).
func active() -> bool:
	return enabled and _rect != null


## Screen point -> the point the CRT shows there (crt.gdshader's warp()).
func warp(point: Vector2) -> Vector2:
	if not active():
		return point
	var size := get_viewport().get_visible_rect().size
	var k: float = _mat.get_shader_parameter("curvature")
	var c := point / size * 2.0 - Vector2.ONE
	c *= Vector2(1.0 + c.y * c.y * k, 1.0 + c.x * c.x * k)
	return (c * 0.5 + Vector2(0.5, 0.5)) * size


func _input(event: InputEvent) -> void:
	if event is InputEventMouse and active() and not event.has_meta("crt"):
		var warped: InputEventMouse = event.duplicate()
		warped.set_meta("crt", true)
		warped.position = warp(event.position)
		warped.global_position = warped.position
		get_viewport().set_input_as_handled()
		get_viewport().push_input(warped, true)
