extends Camera3D
## Demo camera: hold the right mouse button to look around, WASD/QE to move (Shift = fast,
## Alt = slow).

@export var move_speed: float = 2.0
@export var look_sensitivity: float = 0.003

var _yaw := 0.0
var _pitch := 0.0


func _ready() -> void:
	sync_angles()


## Takes yaw and pitch from the current transform (after the demo moves the camera to a view).
func sync_angles() -> void:
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	if motion != null and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_yaw -= motion.relative.x * look_sensitivity
		_pitch = clampf(_pitch - motion.relative.y * look_sensitivity, -1.5, 1.5)
		rotation = Vector3(_pitch, _yaw, 0.0)


func _process(delta: float) -> void:
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		return
	var dir := Vector3.ZERO
	dir.x = float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
	dir.z = float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W))
	dir.y = float(Input.is_key_pressed(KEY_E)) - float(Input.is_key_pressed(KEY_Q))
	var speed := move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= 4.0
	elif Input.is_key_pressed(KEY_ALT):
		speed *= 0.2
	translate(dir.normalized() * speed * delta)
