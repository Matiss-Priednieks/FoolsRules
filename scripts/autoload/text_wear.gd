extends Node
## Autoload: gives every Label / Button the worn-ink material
## (shaders/text_wear.gdshader) and every PlatePanel the worn painted-metal one
## (shaders/worn_panel.gdshader) as it enters the tree, so all the UI looks
## stamped-and-handled without setting anything per node. A node that already
## has its own material is left alone.

const WEAR := preload("res://shaders/text_wear.gdshader")
const PANEL_WEAR := preload("res://shaders/worn_panel.gdshader") # PlatePanel boxes
var _material: ShaderMaterial
var _panel_material: ShaderMaterial


func _ready() -> void:
	_material = ShaderMaterial.new()
	_material.shader = WEAR
	_panel_material = ShaderMaterial.new()
	_panel_material.shader = PANEL_WEAR
	get_tree().node_added.connect(_on_node_added)
	# the main scene can already be in the tree before this autoload is ready
	# (normal launch / F5), so catch what's there too
	_apply_all(get_tree().root)


func _apply_all(node: Node) -> void:
	_on_node_added(node)
	for child in node.get_children(true):
		_apply_all(child)


func _on_node_added(node: Node) -> void:
	if not node is CanvasItem or (node as CanvasItem).material != null:
		return
	if node is Label or node is Button or node is RichTextLabel:
		(node as CanvasItem).material = _material
	elif node is PanelContainer and (node as Control).theme_type_variation == &"PlatePanel":
		(node as CanvasItem).material = _panel_material
