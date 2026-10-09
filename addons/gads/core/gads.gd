@tool
class_name GADS
extends RefCounted
## The short way in for game code: one displacement quality for the whole game (for a graphics
## settings menu: Off, Low, Medium, High, Ultra, changeable at any time) and [GADSSurface], one
## node's relief.
## [codeblock]
## GADS.set_quality(GADS.QUALITY_HIGH)              # from the options menu
## var rock := GADS.surface($Rock)
## rock.displacement_strength = 0.08                  # metres, this node only
## rock.set_height_texture(load("res://rock_height.exr"))
## [/codeblock]

const QUALITY_OFF := GADSSettings.Preset.OFF
const QUALITY_LOW := GADSSettings.Preset.LOW
const QUALITY_MEDIUM := GADSSettings.Preset.MEDIUM
const QUALITY_HIGH := GADSSettings.Preset.HIGH
const QUALITY_ULTRA := GADSSettings.Preset.ULTRA
## The levels' names, by level (for an OptionButton).
const QUALITY_NAMES: PackedStringArray = ["Off", "Low", "Medium", "High", "Ultra"]


## The scene's GADSManager. With [param create], one is added to the scene tree's root when there
## is none (deferred: it applies its preset once it is in the tree).
static func manager(create := false) -> GADSManager:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var m := GADSManager.find_in(tree)
	if m == null:
		m = _pending
	if m == null and create:
		m = GADSManager.new()
		m.name = "GADSManager"
		_pending = m
		tree.root.add_child.call_deferred(m)
		m.tree_entered.connect(func() -> void: _pending = null, CONNECT_ONE_SHOT)
	return m


## Sets the displacement quality of the whole game ([member GADSManager.preset]): QUALITY_OFF
## draws plain normal mapping, QUALITY_ULTRA everything. Adds a GADSManager when there is none.
static func set_quality(level: int) -> void:
	var m := manager(true)
	if m != null:
		m.preset = clampi(level, QUALITY_OFF, QUALITY_ULTRA) as GADSSettings.Preset


## The quality in effect: the manager's preset after its platform cap (Medium without a manager;
## a Custom preset reads as Medium).
static func get_quality() -> int:
	var m := manager()
	if m == null:
		return QUALITY_MEDIUM
	var p := m.get_effective_preset() if m.is_inside_tree() else m.preset
	return p if p <= QUALITY_ULTRA else QUALITY_MEDIUM


## [param node]'s relief, for scripts (see [GADSSurface]).
static func surface(node: GeometryInstance3D) -> GADSSurface:
	return GADSSurface.new(node)


static var _pending: GADSManager
