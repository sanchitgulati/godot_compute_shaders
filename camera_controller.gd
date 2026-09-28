class_name CameraController
extends Node

## CameraController
## Handles Flycam 6-DOF spectator navigation and Camera Animation Presets (e.g. Preset 1 Orbit)
## for GPU raytracing and 3D viewing.

signal mode_changed(new_mode: CameraMode)
signal speed_changed(new_speed: float)

enum CameraMode {
	PRESET_1,  ## Orbital animation preset orbiting the voxel model
	FLYCAM,    ## Free-flight camera with WASD + mouse look
}

# --- Exported Settings ---
@export_group("Mode & Speed")
@export var mode: CameraMode = CameraMode.PRESET_1
@export var fly_speed: float = 20.0
@export var fly_speed_min: float = 2.0
@export var fly_speed_max: float = 300.0
@export var sprint_multiplier: float = 2.5
@export var slow_multiplier: float = 0.3
@export var look_sensitivity: float = 0.003
@export var fov: float = 55.0

@export_group("Preset 1 (Orbit Animation)")
@export var orbit_speed: float = 0.25
@export var auto_orbit: bool = true

# --- Camera State (World Transform) ---
var position := Vector3.ZERO
var yaw: float = 0.75
var pitch: float = -0.35

# --- Preset 1 Orbit State ---
var orbit_target := Vector3.ZERO
var orbit_distance: float = 50.0
var orbit_yaw: float = 0.75
var orbit_pitch: float = -0.35

# --- Input Tracking ---
var is_rmb_down: bool = false
var is_lmb_down: bool = false
var _is_dragging_orbit: bool = false
var _is_dragging_pan: bool = false
var _last_mouse_pos := Vector2.ZERO


func _ready() -> void:
	# Disable standalone processing since VoxelViewer calls update_camera explicitly
	# before dispatching the compute shader pass.
	set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			is_rmb_down = false


## Updates camera state for the current frame.
## Call this before rendering / updating UBO.
func update_camera(delta: float) -> void:
	if mode == CameraMode.PRESET_1:
		if _has_fly_input():
			switch_to_flycam()
			_process_flycam_movement(delta)
		else:
			camera_animation_preset_1(delta)
	elif mode == CameraMode.FLYCAM:
		_process_flycam_movement(delta)


## Camera animation preset 1: Smooth orbital rotation around the voxel structure.
func camera_animation_preset_1(delta: float) -> void:
	if auto_orbit and not _is_dragging_orbit:
		orbit_yaw += orbit_speed * delta

	yaw = orbit_yaw
	pitch = orbit_pitch
	var fwd := get_forward()
	position = orbit_target - fwd * orbit_distance


## Normalized forward view direction vector
func get_forward() -> Vector3:
	var cp := cos(pitch)
	var sp := sin(pitch)
	var cy := cos(yaw)
	var sy := sin(yaw)
	return Vector3(-cp * sy, sp, -cp * cy).normalized()


## Normalized right direction vector
func get_right() -> Vector3:
	return get_forward().cross(Vector3.UP).normalized()


## Normalized up direction vector
func get_up() -> Vector3:
	return get_right().cross(get_forward()).normalized()


## Field of view in radians
func get_fov_radians() -> float:
	return deg_to_rad(fov)


## Configures preset 1 framing and fly speed based on voxel grid dimensions
func setup_for_grid(grid_size: Vector3i) -> void:
	orbit_target = Vector3(grid_size.x, grid_size.y, grid_size.z) * 0.5
	var max_dim := float(maxi(grid_size.x, maxi(grid_size.y, grid_size.z)))
	orbit_distance = max_dim * 1.7
	orbit_yaw = 0.75
	orbit_pitch = -0.35
	fly_speed = clamp(max_dim * 0.5, 5.0, 100.0)
	reset_preset_1()


## Resets camera view to Preset 1 orbit
func reset_preset_1() -> void:
	orbit_yaw = 0.75
	orbit_pitch = -0.35
	yaw = orbit_yaw
	pitch = orbit_pitch
	mode = CameraMode.PRESET_1
	auto_orbit = true
	var fwd := get_forward()
	position = orbit_target - fwd * orbit_distance
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	mode_changed.emit(mode)


## Switches to flycam mode, inheriting current position and orientation
func switch_to_flycam() -> void:
	if mode != CameraMode.FLYCAM:
		# Sync orientation and position
		yaw = orbit_yaw
		pitch = orbit_pitch
		var fwd := get_forward()
		position = orbit_target - fwd * orbit_distance
		mode = CameraMode.FLYCAM
		mode_changed.emit(mode)


## Switches to Preset 1 orbit mode
func switch_to_preset_1() -> void:
	if mode != CameraMode.PRESET_1:
		mode = CameraMode.PRESET_1
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			is_rmb_down = false
		mode_changed.emit(mode)


func set_mode(new_mode: CameraMode) -> void:
	if new_mode == CameraMode.FLYCAM:
		switch_to_flycam()
	else:
		switch_to_preset_1()


func _has_fly_input() -> bool:
	return (
		Input.is_key_pressed(KEY_W) or
		Input.is_key_pressed(KEY_S) or
		Input.is_key_pressed(KEY_A) or
		Input.is_key_pressed(KEY_D) or
		Input.is_key_pressed(KEY_SPACE) or
		Input.is_key_pressed(KEY_E) or
		Input.is_key_pressed(KEY_Q) or
		Input.is_key_pressed(KEY_C)
	)


func _process_flycam_movement(delta: float) -> void:
	var move_input := Vector3.ZERO
	var fwd := get_forward()
	var rgt := get_right()

	if Input.is_key_pressed(KEY_W):
		move_input += fwd
	if Input.is_key_pressed(KEY_S):
		move_input -= fwd
	if Input.is_key_pressed(KEY_D):
		move_input += rgt
	if Input.is_key_pressed(KEY_A):
		move_input -= rgt
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_E):
		move_input += Vector3.UP
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C) or Input.is_key_pressed(KEY_Q):
		move_input -= Vector3.UP

	if move_input != Vector3.ZERO:
		var speed := fly_speed
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= sprint_multiplier
		if Input.is_key_pressed(KEY_ALT):
			speed *= slow_multiplier
		position += move_input.normalized() * speed * delta


## Handles GUI input events forwarded from the main viewport
func handle_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			is_lmb_down = mb.pressed
			_last_mouse_pos = mb.position
			if mode == CameraMode.PRESET_1:
				_is_dragging_orbit = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			is_rmb_down = mb.pressed
			_last_mouse_pos = mb.position
			if mb.pressed:
				if mode == CameraMode.PRESET_1:
					switch_to_flycam()
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mode == CameraMode.PRESET_1:
				_is_dragging_pan = mb.pressed
				_last_mouse_pos = mb.position
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if mode == CameraMode.FLYCAM:
				fly_speed = clamp(fly_speed * 1.15, fly_speed_min, fly_speed_max)
				speed_changed.emit(fly_speed)
			else:
				orbit_distance = clamp(orbit_distance * 0.90, 2.0, 500.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mode == CameraMode.FLYCAM:
				fly_speed = clamp(fly_speed * 0.85, fly_speed_min, fly_speed_max)
				speed_changed.emit(fly_speed)
			else:
				orbit_distance = clamp(orbit_distance * 1.10, 2.0, 500.0)

	elif event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			return

		var mm := event as InputEventMouseMotion
		var delta_pos: Vector2 = mm.relative

		if mode == CameraMode.FLYCAM:
			if is_rmb_down or is_lmb_down:
				yaw -= delta_pos.x * look_sensitivity
				pitch = clamp(pitch - delta_pos.y * look_sensitivity, -1.5, 1.5)
		elif mode == CameraMode.PRESET_1:
			if _is_dragging_orbit:
				orbit_yaw -= delta_pos.x * 0.006
				orbit_pitch = clamp(orbit_pitch - delta_pos.y * 0.006, -1.45, 1.45)
			elif _is_dragging_pan:
				var right_vec := get_right()
				var up_vec := get_up()
				var pan_speed := orbit_distance * 0.0018
				orbit_target += (-right_vec * delta_pos.x + up_vec * delta_pos.y) * pan_speed


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				is_rmb_down = false
				get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F:
			if mode != CameraMode.FLYCAM:
				switch_to_flycam()
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_1:
			switch_to_preset_1()
			get_viewport().set_input_as_handled()

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				is_rmb_down = false

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		yaw -= mm.relative.x * look_sensitivity
		pitch = clamp(pitch - mm.relative.y * look_sensitivity, -1.5, 1.5)
