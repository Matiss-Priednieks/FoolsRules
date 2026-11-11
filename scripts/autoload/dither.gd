extends CanvasLayer
## Autoload: full-screen dither over every scene. It sits just under the UI so
## buttons/labels stay crisp: layer 1 in the game (above the cards on 0, below
## the UI layer on 2); the menu drops it to -1 while open (its controls are on 0,
## its background on -10).

const GAME_LAYER := 1
const MENU_LAYER := -1

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	layer = GAME_LAYER
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/dither.gdshader")
	var rect := ColorRect.new()
	rect.material = mat
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(rect)
