extends Control

## Minecraft Map GPU Voxel Raytracer Viewer
## Dispatches voxel_raytracer.glsl on GPU via RenderingDevice and displays zero-copy using Texture2DRD.
## Supports both procedural diorama scenes (Taichi-style imperative API) and Minecraft NBT structure files.

const CameraController = preload("res://camera_controller.gd")
const ProceduralGenerator = preload("res://procedural_generator.gd")

# Render resolutions
const RESOLUTIONS := [
	{"name": "960 x 540 (Fast)", "size": Vector2i(960, 540)},
	{"name": "1280 x 720 (HD)", "size": Vector2i(1280, 720)},
	{"name": "1600 x 900 (High)", "size": Vector2i(1600, 900)},
	{"name": "1920 x 1080 (FHD)", "size": Vector2i(1920, 1080)}
]

# UI Scales
const UI_SCALES := [
	{"name": "1.0x (Standard)", "scale": 1.0},
	{"name": "1.25x (Medium)", "scale": 1.25},
	{"name": "1.5x (Large)", "scale": 1.5},
	{"name": "1.75x (Extra)", "scale": 1.75},
	{"name": "2.0x (Mac Retina 2x)", "scale": 2.0},
	{"name": "2.5x (Ultra)", "scale": 2.5}
]

# Unified map & procedural scenes list
const MAP_ENTRIES := [
	{"name": "Autumn Diorama (Taichi Ex. 6)", "type": "procedural", "id": "autumn_diorama"},
	{"name": "Cyber Skyscraper Grid (Taichi Ex. 1)", "type": "procedural", "id": "cyber_grid"},
	{"name": "Modern Art Wall (Taichi Ex. 2)", "type": "procedural", "id": "modern_wall"},
	{"name": "Cornell Box (Taichi Ex. 3)", "type": "procedural", "id": "cornell_box"},
	{"name": "Cosmic Red Sphere (Taichi Ex. 4)", "type": "procedural", "id": "cosmic_sphere"},
	{"name": "Cloud City at Night (Taichi Ex. 5)", "type": "procedural", "id": "cloud_city"},
	{"name": "Procedural City Grid (Taichi Ex. 7)", "type": "procedural", "id": "city_grid"},
	{"name": "Ocean Waves & Moon (Taichi Ex. 8)", "type": "procedural", "id": "ocean_waves"},
	{"name": "Cozy Bedroom Interior (Taichi Ex. 9)", "type": "procedural", "id": "cozy_bedroom"},
	{"name": "Sleepy Shrine (40x31x54)", "type": "nbt", "path": "res://maps/sleepy-shrine.nbt"},
	{"name": "Gamestore (15x8x16)", "type": "nbt", "path": "res://maps/gamestore112.nbt"},
	{"name": "Small (5x15x10)", "type": "nbt", "path": "res://maps/small.nbt"},
	{"name": "Test (10x10x6)", "type": "nbt", "path": "res://maps/test.nbt"}
]

@export var render_width: int = 960
@export var render_height: int = 540

# RenderingDevice resources
var rd: RenderingDevice
var shader_rid: RID
var pipeline_rid: RID
var camera_buffer_rid: RID
var voxel_buffer_rid: RID
var out_texture_rid: RID
var uniform_set_rid: RID
var texture_rd: Texture2DRD

# Map state
var current_map_name: String = ""
var current_entry_index: int = 0
var grid_size := Vector3i(1, 1, 1)
var solid_voxel_count: int = 0
var palette_count: int = 0

# Color grading & lighting settings
var saturation: float = 1.25
var gamma: float = 2.20
var contrast: float = 1.12
var exposure: float = 1.45
var sun_angle: float = 5.50
var sun_intensity: float = 2.20
var ambient_light: float = 0.42
var edge_darken: float = 0.0
var edge_threshold: float = 0.06
var floor_y: float = 7.98
var sun_elevation: float = 0.52

# Raytracing feature flags
var enable_shadows: bool = true
var enable_reflections: bool = true
var enable_floor: bool = true
var is_studio_mode: bool = true

# Progressive Path Tracing & Global Illumination
var enable_accumulation: bool = true
var enable_gi: bool = true
var current_spp: int = 1
var max_spp: int = 512
var light_spread: float = 0.20
var gi_bounces: int = 1
var is_converged: bool = false
var _accum_reset_pending: bool = true
var custom_bg_color := Vector3.ZERO
var use_custom_bg: bool = false
var custom_floor_color := Vector3.ZERO
var use_custom_floor: bool = false
var accum_buffer_rid: RID

# Camera movement detection for accumulation reset
var _prev_cam_pos := Vector3.INF
var _prev_cam_fwd := Vector3.INF
var _prev_cam_fov: float = -1.0

# UI Scale
var current_ui_scale: float = 1.0

# Node references
@onready var camera_controller: CameraController = $CameraController
@onready var texture_rect: TextureRect = $TextureRect
@onready var ui_container: Control = $UI
@onready var stats_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/StatsLabel

# Controls
@onready var map_selector: OptionButton = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxMap/MapSelector
@onready var res_selector: OptionButton = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxRes/ResSelector
@onready var scale_selector: OptionButton = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxScale/ScaleSelector
@onready var cam_mode_selector: OptionButton = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxCamera/CamModeSelector
@onready var auto_orbit_check: CheckBox = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxControls/AutoOrbitCheck
@onready var reset_button: Button = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxControls/ResetButton

# Color & Gamma
@onready var sat_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxSat/SatSlider
@onready var sat_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxSat/SatValLabel
@onready var gamma_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxGamma/GammaSlider
@onready var gamma_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxGamma/GammaValLabel
@onready var contrast_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxContrast/ContrastSlider
@onready var contrast_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxContrast/ContrastValLabel
@onready var exposure_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxExposure/ExposureSlider
@onready var exposure_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxExposure/ExposureValLabel

# Lighting & Shadows
@onready var sun_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxSun/SunSlider
@onready var sun_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxSun/SunValLabel
@onready var sun_int_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxSunInt/SunIntSlider
@onready var sun_int_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxSunInt/SunIntValLabel
@onready var amb_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxAmbient/AmbSlider
@onready var amb_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxAmbient/AmbValLabel
@onready var edge_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxEdge/EdgeSlider
@onready var edge_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxEdge/EdgeValLabel

# Toggles
@onready var shadows_check: CheckBox = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxToggles/ShadowsCheck
@onready var refl_check: CheckBox = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxToggles/ReflCheck
@onready var floor_check: CheckBox = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxToggles/FloorCheck
@onready var studio_check: CheckBox = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxToggles/StudioCheck

# Path Tracing & Soft Shadows
@onready var accum_check: CheckBox = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxPathTracing/AccumCheck
@onready var gi_check: CheckBox = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxPathTracing/GICheck
@onready var max_spp_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxMaxSPP/MaxSPPSlider
@onready var max_spp_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxMaxSPP/MaxSPPValLabel
@onready var softness_slider: HSlider = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxSoftness/SoftnessSlider
@onready var softness_val_label: Label = $UI/PanelContainer/MarginContainer/VBoxContainer/ScrollContainer/ControlsVBox/HBoxSoftness/SoftnessValLabel


func _ready() -> void:
	if camera_controller == null:
		camera_controller = CameraController.new()
		camera_controller.name = "CameraController"
		add_child(camera_controller)

	_init_ui()
	_init_rendering_device()
	_init_compute_pipeline()
	_init_output_texture()
	_init_accum_buffer()
	_init_camera_buffer()

	# Auto-detect macOS High DPI (Retina)
	var default_scale: float = 1.0
	if OS.get_name() == "macOS" or DisplayServer.screen_get_scale() >= 1.5:
		default_scale = 2.0
	set_ui_scale(default_scale)

	# Check for command line arguments
	var initial_idx: int = 0
	var cli_sun_angle: Variant = null
	var cli_sun_intensity: Variant = null
	var cli_ambient: Variant = null
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--scene="):
			var s_val := arg.trim_prefix("--scene=")
			if s_val.is_valid_int():
				initial_idx = clampi(s_val.to_int(), 0, MAP_ENTRIES.size() - 1)
			else:
				for i in range(MAP_ENTRIES.size()):
					if MAP_ENTRIES[i].get("id", "") == s_val:
						initial_idx = i
						break
		elif arg.begins_with("--max-spp="):
			max_spp = maxi(16, arg.trim_prefix("--max-spp=").to_int())
		elif arg.begins_with("--sun-angle="):
			cli_sun_angle = arg.trim_prefix("--sun-angle=").to_float()
		elif arg.begins_with("--sun-intensity="):
			cli_sun_intensity = arg.trim_prefix("--sun-intensity=").to_float()
		elif arg.begins_with("--ambient-light="):
			cli_ambient = arg.trim_prefix("--ambient-light=").to_float()
	load_map_entry(initial_idx)

	if cli_sun_angle != null:
		sun_angle = cli_sun_angle
	if cli_sun_intensity != null:
		sun_intensity = cli_sun_intensity
	if cli_ambient != null:
		ambient_light = cli_ambient
	if cli_sun_angle != null or cli_sun_intensity != null or cli_ambient != null:
		_sync_ui_controls()
		reset_accumulation()


func _init_ui() -> void:
	# 1. Map selector
	if map_selector:
		map_selector.clear()
		for i in range(MAP_ENTRIES.size()):
			map_selector.add_item(MAP_ENTRIES[i]["name"], i)
		map_selector.item_selected.connect(load_map_entry)

	# 2. Resolution selector
	if res_selector:
		res_selector.clear()
		for i in range(RESOLUTIONS.size()):
			res_selector.add_item(RESOLUTIONS[i]["name"], i)
			if RESOLUTIONS[i]["size"].x == render_width and RESOLUTIONS[i]["size"].y == render_height:
				res_selector.selected = i
		res_selector.item_selected.connect(func(idx: int):
			if idx >= 0 and idx < RESOLUTIONS.size():
				var res: Vector2i = RESOLUTIONS[idx]["size"]
				set_render_resolution(res.x, res.y)
		)

	# 3. UI Scale selector
	if scale_selector:
		scale_selector.clear()
		for i in range(UI_SCALES.size()):
			scale_selector.add_item(UI_SCALES[i]["name"], i)
		scale_selector.item_selected.connect(func(idx: int):
			if idx >= 0 and idx < UI_SCALES.size():
				set_ui_scale(UI_SCALES[idx]["scale"])
		)

	# 4. Camera controls
	if cam_mode_selector and camera_controller:
		cam_mode_selector.clear()
		cam_mode_selector.add_item("Preset 1 (Orbit)", CameraController.CameraMode.PRESET_1)
		cam_mode_selector.add_item("Flycam (Free Flight)", CameraController.CameraMode.FLYCAM)
		cam_mode_selector.selected = camera_controller.mode
		cam_mode_selector.item_selected.connect(func(idx: int):
			camera_controller.set_mode(idx as CameraController.CameraMode)
		)

	if camera_controller:
		camera_controller.mode_changed.connect(func(new_mode: CameraController.CameraMode):
			if cam_mode_selector and cam_mode_selector.selected != new_mode:
				cam_mode_selector.selected = new_mode
			if auto_orbit_check:
				auto_orbit_check.disabled = (new_mode == CameraController.CameraMode.FLYCAM)
		)

	if auto_orbit_check and camera_controller:
		auto_orbit_check.button_pressed = camera_controller.auto_orbit
		auto_orbit_check.toggled.connect(func(val: bool): camera_controller.auto_orbit = val)

	if reset_button:
		reset_button.pressed.connect(reset_camera)

	# 5. Color & Gamma Sliders
	if sat_slider:
		sat_slider.value = saturation
		if sat_val_label:
			sat_val_label.text = "%.2f" % saturation
		sat_slider.value_changed.connect(func(val: float):
			saturation = val
			if sat_val_label:
				sat_val_label.text = "%.2f" % val
			reset_accumulation()
		)

	if gamma_slider:
		gamma_slider.value = gamma
		if gamma_val_label:
			gamma_val_label.text = "%.2f" % gamma
		gamma_slider.value_changed.connect(func(val: float):
			gamma = val
			if gamma_val_label:
				gamma_val_label.text = "%.2f" % val
			reset_accumulation()
		)

	if contrast_slider:
		contrast_slider.value = contrast
		if contrast_val_label:
			contrast_val_label.text = "%.2f" % contrast
		contrast_slider.value_changed.connect(func(val: float):
			contrast = val
			if contrast_val_label:
				contrast_val_label.text = "%.2f" % val
			reset_accumulation()
		)

	if exposure_slider:
		exposure_slider.value = exposure
		if exposure_val_label:
			exposure_val_label.text = "%.2f" % exposure
		exposure_slider.value_changed.connect(func(val: float):
			exposure = val
			if exposure_val_label:
				exposure_val_label.text = "%.2f" % val
			reset_accumulation()
		)

	# 6. Lighting Sliders
	if sun_slider:
		sun_slider.value = sun_angle
		if sun_val_label:
			sun_val_label.text = "%.2f" % sun_angle
		sun_slider.value_changed.connect(func(val: float):
			sun_angle = val
			if sun_val_label:
				sun_val_label.text = "%.2f" % val
			reset_accumulation()
		)

	if sun_int_slider:
		sun_int_slider.value = sun_intensity
		if sun_int_val_label:
			sun_int_val_label.text = "%.2f" % sun_intensity
		sun_int_slider.value_changed.connect(func(val: float):
			sun_intensity = val
			if sun_int_val_label:
				sun_int_val_label.text = "%.2f" % val
			reset_accumulation()
		)

	if amb_slider:
		amb_slider.value = ambient_light
		if amb_val_label:
			amb_val_label.text = "%.2f" % ambient_light
		amb_slider.value_changed.connect(func(val: float):
			ambient_light = val
			if amb_val_label:
				amb_val_label.text = "%.2f" % val
			reset_accumulation()
		)

	if edge_slider:
		edge_slider.value = edge_darken
		if edge_val_label:
			edge_val_label.text = "%d%%" % round(edge_darken * 100)
		edge_slider.value_changed.connect(func(val: float):
			edge_darken = val
			if edge_val_label:
				edge_val_label.text = "%d%%" % round(val * 100)
			reset_accumulation()
		)

	# 7. Raytracing Toggles
	if shadows_check:
		shadows_check.button_pressed = enable_shadows
		shadows_check.toggled.connect(func(val: bool):
			enable_shadows = val
			reset_accumulation()
		)

	if refl_check:
		refl_check.button_pressed = enable_reflections
		refl_check.toggled.connect(func(val: bool):
			enable_reflections = val
			reset_accumulation()
		)

	if floor_check:
		floor_check.button_pressed = enable_floor
		floor_check.toggled.connect(func(val: bool):
			enable_floor = val
			reset_accumulation()
		)

	if studio_check:
		studio_check.button_pressed = is_studio_mode
		studio_check.toggled.connect(func(val: bool):
			is_studio_mode = val
			reset_accumulation()
		)

	# 8. Path Tracing & Soft Shadows
	if accum_check:
		accum_check.button_pressed = enable_accumulation
		accum_check.toggled.connect(func(val: bool):
			enable_accumulation = val
			reset_accumulation()
		)

	if gi_check:
		gi_check.button_pressed = enable_gi
		gi_check.toggled.connect(func(val: bool):
			enable_gi = val
			reset_accumulation()
		)

	if max_spp_slider:
		max_spp_slider.value = float(max_spp)
		if max_spp_val_label:
			max_spp_val_label.text = str(max_spp)
		max_spp_slider.value_changed.connect(func(val: float):
			max_spp = int(val)
			if max_spp_val_label:
				max_spp_val_label.text = str(max_spp)
			if current_spp >= max_spp:
				is_converged = true
			else:
				is_converged = false
		)

	if softness_slider:
		softness_slider.value = light_spread
		if softness_val_label:
			softness_val_label.text = "%.2f" % light_spread
		softness_slider.value_changed.connect(func(val: float):
			light_spread = val
			if softness_val_label:
				softness_val_label.text = "%.2f" % val
			reset_accumulation()
		)


func _sync_ui_controls() -> void:
	if sat_slider: sat_slider.value = saturation
	if sat_val_label: sat_val_label.text = "%.2f" % saturation
	if gamma_slider: gamma_slider.value = gamma
	if gamma_val_label: gamma_val_label.text = "%.2f" % gamma
	if contrast_slider: contrast_slider.value = contrast
	if contrast_val_label: contrast_val_label.text = "%.2f" % contrast
	if exposure_slider: exposure_slider.value = exposure
	if exposure_val_label: exposure_val_label.text = "%.2f" % exposure
	if sun_slider: sun_slider.value = sun_angle
	if sun_val_label: sun_val_label.text = "%.2f" % sun_angle
	if sun_int_slider: sun_int_slider.value = sun_intensity
	if sun_int_val_label: sun_int_val_label.text = "%.2f" % sun_intensity
	if amb_slider: amb_slider.value = ambient_light
	if amb_val_label: amb_val_label.text = "%.2f" % ambient_light
	if edge_slider: edge_slider.value = edge_darken
	if edge_val_label: edge_val_label.text = "%d%%" % round(edge_darken * 100)
	if studio_check: studio_check.button_pressed = is_studio_mode
	if accum_check: accum_check.button_pressed = enable_accumulation
	if gi_check: gi_check.button_pressed = enable_gi
	if max_spp_slider: max_spp_slider.value = float(max_spp)
	if max_spp_val_label: max_spp_val_label.text = str(max_spp)
	if softness_slider: softness_slider.value = light_spread
	if softness_val_label: softness_val_label.text = "%.2f" % light_spread


func set_ui_scale(scale_val: float) -> void:
	current_ui_scale = scale_val
	get_window().content_scale_factor = scale_val
	if scale_selector:
		for i in range(UI_SCALES.size()):
			if is_equal_approx(UI_SCALES[i]["scale"], scale_val):
				scale_selector.selected = i
				break
	print("[VoxelViewer] UI scale set to %.2fx" % scale_val)


func set_render_resolution(w: int, h: int) -> void:
	if w == render_width and h == render_height and out_texture_rid.is_valid() and accum_buffer_rid.is_valid():
		return
	print("[VoxelViewer] Changing resolution to %dx%d" % [w, h])
	render_width = w
	render_height = h
	_init_output_texture()
	_init_accum_buffer()
	_rebuild_uniform_set()
	reset_accumulation()


func load_map_entry(index: int) -> void:
	if index < 0 or index >= MAP_ENTRIES.size():
		return
	current_entry_index = index
	if map_selector and map_selector.selected != index:
		map_selector.selected = index

	var entry: Dictionary = MAP_ENTRIES[index]
	if entry["type"] == "procedural":
		load_procedural_scene(entry["id"])
	else:
		load_map(entry["path"])


func load_procedural_scene(scene_id: String) -> void:
	print("[VoxelViewer] Generating procedural scene: ", scene_id)
	var result: Dictionary
	if scene_id == "autumn_diorama":
		result = ProceduralGenerator.generate_autumn_diorama()
	elif scene_id == "cyber_grid":
		result = ProceduralGenerator.generate_skyscraper_city()
	elif scene_id == "modern_wall":
		result = ProceduralGenerator.generate_modern_wall()
	elif scene_id == "cornell_box":
		result = ProceduralGenerator.generate_cornell_box()
	elif scene_id == "cosmic_sphere":
		result = ProceduralGenerator.generate_cosmic_sphere()
	elif scene_id == "cloud_city":
		result = ProceduralGenerator.generate_cloud_city()
	elif scene_id == "city_grid":
		result = ProceduralGenerator.generate_city_grid()
	elif scene_id == "ocean_waves":
		result = ProceduralGenerator.generate_ocean_waves()
	elif scene_id == "cozy_bedroom":
		result = ProceduralGenerator.generate_cozy_bedroom()
	else:
		push_error("Unknown procedural scene: " + scene_id)
		return

	current_map_name = result["name"]
	grid_size = result["size"]
	solid_voxel_count = result["solid_count"]
	palette_count = 0

	# Apply scene lighting presets
	is_studio_mode = result.get("is_studio", true)
	floor_y = result.get("floor_y", 7.98)
	sun_angle = result.get("sun_angle", 5.80)
	sun_elevation = result.get("sun_elevation", 0.52)
	sun_intensity = result.get("sun_intensity", 2.30)
	ambient_light = result.get("ambient_light", 0.26)
	edge_darken = result.get("edge_darken", 0.0)
	exposure = result.get("exposure", 1.85)
	saturation = result.get("saturation", 1.08)
	contrast = result.get("contrast", 1.02)
	gamma = result.get("gamma", 2.20)
	enable_reflections = false
	light_spread = result.get("light_spread", 0.20)
	enable_gi = result.get("enable_gi", true)
	gi_bounces = result.get("gi_bounces", 1)
	enable_floor = result.get("enable_floor", true)
	custom_bg_color = result.get("custom_bg", Vector3.ZERO)
	use_custom_bg = result.get("use_custom_bg", false)
	custom_floor_color = result.get("custom_floor", Vector3.ZERO)
	use_custom_floor = result.get("use_custom_floor", false)
	enable_accumulation = true
	reset_accumulation()

	_sync_ui_controls()

	var voxel_bytes: PackedByteArray = result["voxel_data"]

	if voxel_buffer_rid.is_valid():
		rd.free_rid(voxel_buffer_rid)
		voxel_buffer_rid = RID()

	voxel_buffer_rid = rd.storage_buffer_create(voxel_bytes.size(), voxel_bytes)
	_rebuild_uniform_set()

	if camera_controller:
		camera_controller.orbit_target = result.get("camera_target", Vector3(float(grid_size.x) * 0.5, 38.0, float(grid_size.z) * 0.5))
		camera_controller.orbit_distance = result.get("camera_distance", 204.0)
		camera_controller.orbit_yaw = result.get("camera_yaw", 0.72)
		camera_controller.orbit_pitch = result.get("camera_pitch", -0.44)
		camera_controller.yaw = camera_controller.orbit_yaw
		camera_controller.pitch = camera_controller.orbit_pitch
		camera_controller.fov = result.get("camera_fov", 40.0)
		camera_controller.mode = CameraController.CameraMode.PRESET_1
		camera_controller.auto_orbit = false
		var fwd := camera_controller.get_forward()
		camera_controller.position = camera_controller.orbit_target - fwd * camera_controller.orbit_distance
		if auto_orbit_check:
			auto_orbit_check.button_pressed = false

	_update_stats_label()
	print("[VoxelViewer] Procedural scene ready: %s | Solid voxels: %d" % [current_map_name, solid_voxel_count])


func load_map(map_path: String) -> void:
	print("[VoxelViewer] Loading Minecraft structure: ", map_path)
	var result := NBTReader.load_nbt_structure(map_path)
	if result.is_empty():
		push_error("Failed to load map: " + map_path)
		return

	current_map_name = map_path.get_file()
	grid_size = result["size"]
	solid_voxel_count = result["solid_count"]
	palette_count = result["palette"].size()

	# Outdoor Minecraft lighting presets
	is_studio_mode = false
	floor_y = -0.02
	sun_angle = 0.65
	sun_intensity = 2.0
	ambient_light = 0.28
	edge_darken = 0.45
	exposure = 1.10
	saturation = 1.35
	contrast = 1.15
	gamma = 2.20
	light_spread = 0.08
	enable_gi = true
	gi_bounces = 1
	enable_floor = true
	use_custom_bg = false
	use_custom_floor = false
	enable_accumulation = true
	reset_accumulation()

	_sync_ui_controls()

	var voxel_bytes: PackedByteArray = result["voxel_data"]

	if voxel_buffer_rid.is_valid():
		rd.free_rid(voxel_buffer_rid)
		voxel_buffer_rid = RID()

	voxel_buffer_rid = rd.storage_buffer_create(voxel_bytes.size(), voxel_bytes)
	_rebuild_uniform_set()

	reset_camera()
	_update_stats_label()
	print("[VoxelViewer] Map loaded: %s | Size: %s | Solid: %d | Palette: %d" % [
		map_path, str(grid_size), solid_voxel_count, palette_count
	])


func reset_camera() -> void:
	if camera_controller:
		camera_controller.setup_for_grid(grid_size)


func _init_rendering_device() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		rd = RenderingServer.create_local_rendering_device()
	assert(rd != null, "RenderingDevice is not available! Forward+ renderer is required.")


func _init_compute_pipeline() -> void:
	var shader_file: RDShaderFile = load("res://voxel_raytracer.glsl")
	assert(shader_file != null, "Failed to load res://voxel_raytracer.glsl")
	var shader_spirv := shader_file.get_spirv()
	shader_rid = rd.shader_create_from_spirv(shader_spirv)
	assert(shader_rid.is_valid(), "Failed to create shader from SPIR-V")
	pipeline_rid = rd.compute_pipeline_create(shader_rid)


func _init_output_texture() -> void:
	if out_texture_rid.is_valid():
		rd.free_rid(out_texture_rid)
		out_texture_rid = RID()

	var fmt := RDTextureFormat.new()
	fmt.width = render_width
	fmt.height = render_height
	fmt.depth = 1
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT |
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT |
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	)

	out_texture_rid = rd.texture_create(fmt, RDTextureView.new())
	if texture_rd == null:
		texture_rd = Texture2DRD.new()
	texture_rd.texture_rd_rid = out_texture_rid
	if texture_rect:
		texture_rect.texture = texture_rd


func _init_accum_buffer() -> void:
	if accum_buffer_rid.is_valid():
		rd.free_rid(accum_buffer_rid)
		accum_buffer_rid = RID()

	var byte_size := render_width * render_height * 16
	var empty_bytes := PackedByteArray()
	empty_bytes.resize(byte_size)
	empty_bytes.fill(0)
	accum_buffer_rid = rd.storage_buffer_create(byte_size, empty_bytes)


func _init_camera_buffer() -> void:
	# 12 vec4s = 192 bytes
	if camera_buffer_rid.is_valid():
		rd.free_rid(camera_buffer_rid)
		camera_buffer_rid = RID()

	var empty_bytes := PackedByteArray()
	empty_bytes.resize(192)
	empty_bytes.fill(0)
	camera_buffer_rid = rd.uniform_buffer_create(192, empty_bytes)


func _rebuild_uniform_set() -> void:
	if not rd or not camera_buffer_rid.is_valid() or not voxel_buffer_rid.is_valid() or not out_texture_rid.is_valid() or not accum_buffer_rid.is_valid():
		return

	if uniform_set_rid.is_valid():
		rd.free_rid(uniform_set_rid)
		uniform_set_rid = RID()

	var u_cam := RDUniform.new()
	u_cam.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u_cam.binding = 0
	u_cam.add_id(camera_buffer_rid)

	var u_voxels := RDUniform.new()
	u_voxels.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_voxels.binding = 1
	u_voxels.add_id(voxel_buffer_rid)

	var u_image := RDUniform.new()
	u_image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_image.binding = 2
	u_image.add_id(out_texture_rid)

	var u_accum := RDUniform.new()
	u_accum.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_accum.binding = 3
	u_accum.add_id(accum_buffer_rid)

	uniform_set_rid = rd.uniform_set_create([u_cam, u_voxels, u_image, u_accum], shader_rid, 0)


func reset_accumulation() -> void:
	current_spp = 1
	is_converged = false
	_accum_reset_pending = true


func _check_camera_movement() -> void:
	if not camera_controller:
		return
	var cur_pos := camera_controller.position
	var cur_fwd := camera_controller.get_forward()
	var cur_fov := camera_controller.get_fov_radians()

	var cam_changed := not cur_pos.is_equal_approx(_prev_cam_pos) or not cur_fwd.is_equal_approx(_prev_cam_fwd) or not is_equal_approx(cur_fov, _prev_cam_fov)
	if cam_changed:
		_prev_cam_pos = cur_pos
		_prev_cam_fwd = cur_fwd
		_prev_cam_fov = cur_fov
		reset_accumulation()

	# If an accumulation reset is pending (triggered by UI sliders, toggles, map loading, or camera movement),
	# dispatch sample 1 with current_spp = 1 on this frame so the GPU compute shader clears the accumulation buffer.
	if _accum_reset_pending:
		_accum_reset_pending = false
		current_spp = 1
		is_converged = false
		return

	if enable_accumulation:
		if current_spp < max_spp:
			current_spp += 1
			is_converged = false
		else:
			is_converged = true


func _process(delta: float) -> void:
	if camera_controller:
		camera_controller.update_camera(delta)

	_check_camera_movement()
	_update_camera_ubo()
	_dispatch_compute()
	_update_stats_label()

	for arg in OS.get_cmdline_args():
		if arg == "--hide-ui":
			if ui_container and ui_container.visible:
				ui_container.visible = false
		elif arg.begins_with("--capture-spp="):
			var target_spp := arg.trim_prefix("--capture-spp=").to_int()
			if current_spp >= target_spp:
				var img := get_viewport().get_texture().get_image()
				if img and not img.is_empty():
					var out_path := "res://test_render.png"
					for o_arg in OS.get_cmdline_args():
						if o_arg.begins_with("--output="):
							out_path = o_arg.trim_prefix("--output=")
					img.save_png(out_path)
					print("[VoxelViewer] Saved benchmark render at %d SPP to %s" % [current_spp, out_path])
					get_tree().quit()


func _update_camera_ubo() -> void:
	if not camera_buffer_rid.is_valid() or not camera_controller:
		return

	var cam_pos := camera_controller.position
	var cam_forward := camera_controller.get_forward()
	var cam_right := camera_controller.get_right()
	var cam_up := camera_controller.get_up()
	var fov_rad := camera_controller.get_fov_radians()

	# Sun direction from sun_angle
	var sun_dir := Vector3(cos(sun_angle), sun_elevation, sin(sun_angle)).normalized()

	# Render flags bitmask (bit 0: shadow, bit 1: refl, bit 2: floor, bit 3: studio)
	var render_flags: int = 0
	if enable_shadows:
		render_flags |= 1
	if enable_reflections:
		render_flags |= 2
	if enable_floor:
		render_flags |= 4
	if is_studio_mode:
		render_flags |= 8

	# Pack 12 vec4s (192 bytes total)
	var spb := StreamPeerBuffer.new()
	spb.data_array.resize(192)
	spb.big_endian = false  # Little-endian for standard GPU float layout

	# 0..15: cam_pos.xyz, fov_rad
	spb.put_float(cam_pos.x)
	spb.put_float(cam_pos.y)
	spb.put_float(cam_pos.z)
	spb.put_float(fov_rad)

	# 16..31: cam_dir.xyz, render_flags
	spb.put_float(cam_forward.x)
	spb.put_float(cam_forward.y)
	spb.put_float(cam_forward.z)
	spb.put_float(float(render_flags))

	# 32..47: cam_up.xyz, edge_threshold
	spb.put_float(cam_up.x)
	spb.put_float(cam_up.y)
	spb.put_float(cam_up.z)
	spb.put_float(edge_threshold)

	# 48..63: cam_right.xyz, ambient_light
	spb.put_float(cam_right.x)
	spb.put_float(cam_right.y)
	spb.put_float(cam_right.z)
	spb.put_float(ambient_light)

	# 64..79: grid_size.xyz, max_steps
	spb.put_float(float(grid_size.x))
	spb.put_float(float(grid_size.y))
	spb.put_float(float(grid_size.z))
	var max_dim := float(maxi(grid_size.x, maxi(grid_size.y, grid_size.z)))
	spb.put_float(max_dim * 3.5 + 64.0)

	# 80..95: light_dir.xyz, edge_darken_strength
	spb.put_float(sun_dir.x)
	spb.put_float(sun_dir.y)
	spb.put_float(sun_dir.z)
	spb.put_float(edge_darken)

	# 96..111: screen_size (xy = res, z = floor_y, w = exposure)
	spb.put_float(float(render_width))
	spb.put_float(float(render_height))
	spb.put_float(floor_y)
	spb.put_float(exposure)

	# 112..127: post_process (x = gamma, y = saturation, z = contrast, w = sun_intensity)
	spb.put_float(gamma)
	spb.put_float(saturation)
	spb.put_float(contrast)
	spb.put_float(sun_intensity)

	# 128..143: accum_params (x = current_spp, y = max_spp, z = light_spread, w = enable_gi)
	spb.put_float(float(current_spp))
	spb.put_float(float(max_spp))
	spb.put_float(light_spread)
	spb.put_float(1.0 if enable_gi else 0.0)

	# 144..159: extra_params (x = gi_bounces, y = gi_intensity, z = enable_accumulation, w = reserved)
	spb.put_float(float(gi_bounces))
	spb.put_float(1.0)
	spb.put_float(1.0 if enable_accumulation else 0.0)
	spb.put_float(0.0)

	# 160..175: bg_color (xyz = color, w = use_custom_bg)
	spb.put_float(custom_bg_color.x)
	spb.put_float(custom_bg_color.y)
	spb.put_float(custom_bg_color.z)
	spb.put_float(1.0 if use_custom_bg else 0.0)

	# 176..191: floor_color (xyz = color, w = use_custom_floor)
	spb.put_float(custom_floor_color.x)
	spb.put_float(custom_floor_color.y)
	spb.put_float(custom_floor_color.z)
	spb.put_float(1.0 if use_custom_floor else 0.0)

	rd.buffer_update(camera_buffer_rid, 0, 192, spb.data_array)


var _has_dispatched_first_frame: bool = false
func _dispatch_compute() -> void:
	if not uniform_set_rid.is_valid() or not pipeline_rid.is_valid():
		return
	if enable_accumulation and is_converged:
		return

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline_rid)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set_rid, 0)

	var groups_x := int(ceil(float(render_width) / 8.0))
	var groups_y := int(ceil(float(render_height) / 8.0))
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	rd.compute_list_end()

	if not _has_dispatched_first_frame:
		_has_dispatched_first_frame = true
		print("[VoxelViewer] Raytracer compute dispatched successfully (%dx%d, %dx%d workgroups)!" % [
			render_width, render_height, groups_x, groups_y
		])


func _update_stats_label() -> void:
	if not stats_label:
		return
	var fps := Engine.get_frames_per_second()
	var mode_name := "Preset 1"
	if camera_controller:
		if camera_controller.mode == CameraController.CameraMode.FLYCAM:
			mode_name = "Flycam (Spd: %.0f)" % camera_controller.fly_speed
		else:
			mode_name = "Preset 1 (Orbit)"

	var accum_str := ""
	if enable_accumulation:
		if current_spp >= max_spp:
			accum_str = " | %d/%d SPP (Converged)" % [current_spp, max_spp]
		else:
			accum_str = " | %d/%d SPP..." % [current_spp, max_spp]
	else:
		accum_str = " | Realtime (1 SPP)"

	stats_label.text = "%s | %dx%d | %s | %d FPS%s" % [
		current_map_name,
		render_width, render_height,
		mode_name,
		fps,
		accum_str
	]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed() and not event.is_echo():
		if event.keycode == KEY_H or event.keycode == KEY_TAB:
			if ui_container:
				ui_container.visible = not ui_container.visible
				get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F12:
			var img := get_viewport().get_texture().get_image()
			if img and not img.is_empty():
				var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
				var file_name := "res://screenshot_%s.png" % timestamp
				img.save_png(file_name)
				print("[VoxelViewer] Saved screenshot to %s!" % file_name)
				get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	if camera_controller:
		camera_controller.handle_gui_input(event)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_cleanup()


func _cleanup() -> void:
	if rd:
		if uniform_set_rid.is_valid():
			rd.free_rid(uniform_set_rid)
		if voxel_buffer_rid.is_valid():
			rd.free_rid(voxel_buffer_rid)
		if camera_buffer_rid.is_valid():
			rd.free_rid(camera_buffer_rid)
		if accum_buffer_rid.is_valid():
			rd.free_rid(accum_buffer_rid)
		if out_texture_rid.is_valid():
			rd.free_rid(out_texture_rid)
		if pipeline_rid.is_valid():
			rd.free_rid(pipeline_rid)
		if shader_rid.is_valid():
			rd.free_rid(shader_rid)
