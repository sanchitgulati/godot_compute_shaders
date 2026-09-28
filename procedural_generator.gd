class_name ProceduralGenerator
extends RefCounted

## Procedural Voxel Map Generator
## Provides an intuitive imperative API (create_block, create_tree, create_leaves, make_fence)
## to construct procedural voxel diorama scenes in memory without requiring external NBT files.

var grid_size: Vector3i
var offset: Vector3i
var data: PackedByteArray
var solid_count: int = 0


func _init(size: Vector3i = Vector3i(128, 128, 128), world_offset: Vector3i = Vector3i(64, 64, 64)) -> void:
	grid_size = size
	offset = world_offset
	data = PackedByteArray()
	data.resize(grid_size.x * grid_size.y * grid_size.z * 4)
	data.fill(0)
	solid_count = 0


## Sets a single voxel at world_pos (maps to grid_pos via offset)
## mat_id: 1=diffuse, 2=light, 3=water, 4=glass, 5=metal
func set_voxel(world_pos: Vector3i, mat_id: int, color: Vector3) -> void:
	var gp := world_pos + offset
	if gp.x < 0 or gp.x >= grid_size.x or gp.y < 0 or gp.y >= grid_size.y or gp.z < 0 or gp.z >= grid_size.z:
		return
	var idx := (gp.x + gp.y * grid_size.x + gp.z * grid_size.x * grid_size.y) * 4
	var was_solid: bool = (data[idx + 3] != 0)
	data[idx] = int(clampf(color.x * 255.0, 0.0, 255.0))
	data[idx + 1] = int(clampf(color.y * 255.0, 0.0, 255.0))
	data[idx + 2] = int(clampf(color.z * 255.0, 0.0, 255.0))
	data[idx + 3] = mat_id
	if not was_solid and mat_id != 0:
		solid_count += 1
	elif was_solid and mat_id == 0:
		solid_count -= 1


## Returns [mat_id: int, color: Vector3] at world_pos
func get_voxel(world_pos: Vector3i) -> Array:
	var gp := world_pos + offset
	if gp.x < 0 or gp.x >= grid_size.x or gp.y < 0 or gp.y >= grid_size.y or gp.z < 0 or gp.z >= grid_size.z:
		return [0, Vector3.ZERO]
	var idx := (gp.x + gp.y * grid_size.x + gp.z * grid_size.x * grid_size.y) * 4
	var mat_id: int = data[idx + 3]
	var col := Vector3(float(data[idx]) / 255.0, float(data[idx + 1]) / 255.0, float(data[idx + 2]) / 255.0)
	return [mat_id, col]


## Fills an axis-aligned bounding box with voxels
func create_block(pos: Vector3i, size: Vector3i, color: Vector3, color_noise: Vector3) -> void:
	fill_block(pos, size, 1, color, color_noise)


## Fills an axis-aligned bounding box with voxels of specified mat_id
func fill_block(pos: Vector3i, size: Vector3i, mat_id: int, color: Vector3 = Vector3.ZERO, color_noise: Vector3 = Vector3.ZERO) -> void:
	for x in range(pos.x, pos.x + size.x):
		for y in range(pos.y, pos.y + size.y):
			for z in range(pos.z, pos.z + size.z):
				var n := randf()
				var c := (color + color_noise * n).clamp(Vector3.ZERO, Vector3.ONE) if mat_id != 0 else Vector3.ZERO
				set_voxel(Vector3i(x, y, z), mat_id, c)



## Creates dense, organic leafy clusters using spherical/parabolic probability distribution with trigonometric noise
func create_leaves(pos: Vector3i, radius: int, color: Vector3) -> void:
	var r_float := float(radius)
	for dx in range(-radius, radius):
		for dy in range(-radius, radius):
			for dz in range(-radius, radius):
				var f := Vector3(float(dx), float(dy), float(dz)) / r_float
				var h := 0.5 - maxf(f.y, -0.5) * 0.5
				var d := Vector2(f.x, f.z).length()
				var prob := pow(maxf(0.0, 1.0 - d), 2.0) * h
				prob *= h  # Vertical parabolic mask
				# Trigonometric surface displacement noise
				prob += sin(f.x * 5.0 + float(pos.x)) * 0.02
				prob += sin(f.y * 9.0 + float(pos.y)) * 0.01
				prob += sin(f.z * 10.0 + float(pos.z)) * 0.03
				if prob < 0.1:
					prob = 0.0
				if randf() < prob:
					var leaf_noise := (randf() - 0.5) * 0.2
					var leaf_col := (color + Vector3.ONE * leaf_noise).clamp(Vector3.ZERO, Vector3.ONE)
					set_voxel(pos + Vector3i(dx, dy, dz), 1, leaf_col)


## Constructs a complete tree with birch trunk, volumetric foliage, and fallen ground leaves
func create_tree(pos: Vector3i, height: int, radius: int, color: Vector3) -> void:
	# 1. Trunk (birch wood with subtle color noise)
	var trunk_h := int(float(height) - float(radius) * 0.5)
	create_block(pos, Vector3i(3, trunk_h, 3), Vector3(0.7, 0.7, 0.7), Vector3(0.3, 0.3, 0.3))

	# 2. Leaves crown
	create_leaves(pos + Vector3i(0, height, 0), radius, color)

	# 3. Ground fallen leaves scattered around base with quadratic radial falloff
	var r_float := float(radius)
	for i in range(-radius, radius):
		for j in range(-radius, radius):
			var d := Vector2(float(i), float(j)).length()
			var prob := maxf((r_float - d) / r_float, 0.0)
			prob = prob * prob
			if randf() < prob * prob:
				var g_col := (color + randf() * Vector3(0.1, 0.1, 0.1)).clamp(Vector3.ZERO, Vector3.ONE)
				set_voxel(pos + Vector3i(i, 1, j), 1, g_col)


## Builds a wooden fence with horizontal railing and evenly spaced vertical posts
func make_fence(start: Vector3i, direction: Vector3i, length: int) -> void:
	var color := Vector3(0.5, 0.3, 0.2)
	# Continuous horizontal rail
	create_block(start, direction * length + Vector3i(3, 2, 3), color, Vector3(0.1, 0.1, 0.1))

	# Vertical fence posts every 3 voxels
	var fence_dist := 3
	for i in range(int(length / fence_dist) + 1):
		create_block(start + direction * i * fence_dist + Vector3i(1, -3, 1), Vector3i(1, 5, 1), color, Vector3.ZERO)


# =========================================================================
# Preset Scene Generators
# =========================================================================

## Generates the Autumn Diorama matching the Taichi Voxel Challenge specification
static func generate_autumn_diorama(seed_val: int = 42) -> Dictionary:
	seed(seed_val)
	var script_res: GDScript = load("res://procedural_generator.gd")
	var gen = script_res.new(Vector3i(128, 128, 128), Vector3i(64, 64, 64))

	# 1. 4 Strata rock / soil base layers beneath the diorama
	var strata_heights := [2, 4, 6, 8]
	var cur_base_y := -40
	for i in range(4):
		var h: int = strata_heights[i]
		cur_base_y -= h
		var base_col := Vector3(0.52 - float(i) * 0.10, 0.50 - float(i) * 0.10, 0.48 - float(i) * 0.10) * Vector3(1.0, 0.82, 0.62)
		gen.create_block(
			Vector3i(-60, cur_base_y, -60),
			Vector3i(120, h, 120),
			base_col,
			Vector3(0.04 * float(3 - i), 0.04 * float(3 - i), 0.04 * float(3 - i))
		)

	# 2. Top soil layer
	gen.create_block(
		Vector3i(-60, -40, -60),
		Vector3i(120, 1, 120),
		Vector3(0.3, 0.2, 0.1),
		Vector3(0.01, 0.01, 0.01)
	)

	# 3. Autumn trees (5 trees with varying heights, crown radii, and foliage hues)
	# Red tree (left)
	gen.create_tree(Vector3i(-20, -40, 25), 65, 35, Vector3(0.85, 0.28, 0.14))
	# Small yellow tree (far right)
	gen.create_tree(Vector3i(45, -40, -45), 15, 10, Vector3(0.80, 0.52, 0.18))
	# Large golden tree (center)
	gen.create_tree(Vector3i(20, -40, 0), 45, 25, Vector3(0.92, 0.45, 0.12))
	# Medium orange tree (front center)
	gen.create_tree(Vector3i(30, -40, -20), 25, 15, Vector3(0.95, 0.48, 0.10))
	# Back orange tree
	gen.create_tree(Vector3i(30, -40, 30), 45, 25, Vector3(0.90, 0.42, 0.12))

	# 4. Perimeter wooden fences
	gen.make_fence(Vector3i(-58, -36, -58), Vector3i(1, 0, 0), 115)
	gen.make_fence(Vector3i(-59, -36, 57), Vector3i(1, 0, 0), 115)
	gen.make_fence(Vector3i(-59, -36, -58), Vector3i(0, 0, 1), 115)
	gen.make_fence(Vector3i(57, -36, -58), Vector3i(0, 0, 1), 115)

	return {
		"name": "Autumn Diorama (Procedural 128³)",
		"type": "procedural",
		"size": gen.grid_size,
		"solid_count": gen.solid_count,
		"palette": [],
		"voxel_data": gen.data,
		"is_studio": true,
		"floor_y": 3.98,
		"sun_angle": 6.03,            # Directional light casting shadow to upper-left matching reference (-14.5 deg)
		"sun_elevation": 0.52,        # Grazing elevation throwing long shadow across floor
		"sun_intensity": 1.85,
		"ambient_light": 0.26,        # Ambient matching Taichi 0.2
		"edge_darken": 0.0,           # Smooth voxel edges matching Taichi voxel_edges=0
		"exposure": 1.65,
		"saturation": 1.15,
		"contrast": 1.05,
		"gamma": 2.20,
		"light_spread": 0.18,         # Tightened spread for crisper penumbra matching reference
		"enable_gi": true,
		"camera_target": Vector3(56.0, 34.0, 68.0),
		"camera_yaw": 0.72,           # Framing matching reference with shadow room
		"camera_pitch": -0.37,        # Lower angle (~21 deg) matches reference tall base & trunks
		"camera_distance": 260.0,     # Farther distance with telephoto FOV
		"camera_fov": 30.0            # Narrow 30 deg FOV eliminates perspective distortion
	}


# =========================================================================
# Taichi Voxel Challenge: Example 1 (Cyber Skyscraper Grid)
# =========================================================================
static func generate_skyscraper_city(seed_val: int = 42) -> Dictionary:
	seed(seed_val)
	var script_res: GDScript = load("res://procedural_generator.gd")
	var gen = script_res.new(Vector3i(64, 32, 64), Vector3i(7, 2, 7))
	var n := 50
	for i in range(n):
		for j in range(n):
			if mini(i, j) == 0 or maxi(i, j) == n - 1:
				gen.set_voxel(Vector3i(i, 0, j), 2, Vector3(0.9, 0.1, 0.1))
			else:
				gen.set_voxel(Vector3i(i, 0, j), 1, Vector3(0.9, 0.1, 0.1))
				if randf() < 0.04:
					var height := int(randf() * 20.0)
					for k in range(1, height):
						gen.set_voxel(Vector3i(i, k, j), 1, Vector3(0.0, 0.5, 0.9))
					if height > 0:
						gen.set_voxel(Vector3i(i, height, j), 2, Vector3(1.0, 1.0, 1.0))

	return {
		"name": "Cyber Skyscraper Grid (Taichi Ex. 1)",
		"type": "procedural",
		"size": gen.grid_size,
		"solid_count": gen.solid_count,
		"palette": [],
		"voxel_data": gen.data,
		"is_studio": false,
		"floor_y": 1.95,
		"custom_floor": Vector3(1.0, 1.0, 1.0),
		"use_custom_floor": true,
		"custom_bg": Vector3(0.015, 0.015, 0.025),
		"use_custom_bg": true,
		"sun_angle": 5.80,
		"sun_elevation": 0.65,
		"sun_intensity": 1.60,
		"ambient_light": 0.20,
		"edge_darken": 0.0,
		"exposure": 2.20,
		"saturation": 1.25,
		"contrast": 1.10,
		"gamma": 2.20,
		"light_spread": 0.15,
		"enable_gi": true,
		"camera_target": Vector3(32.0, 8.0, 32.0),
		"camera_yaw": 0.78,
		"camera_pitch": -0.48,
		"camera_distance": 85.0,
		"camera_fov": 42.0
	}


# =========================================================================
# Taichi Voxel Challenge: Example 2 (Modern Art Wall)
# =========================================================================
static func generate_modern_wall() -> Dictionary:
	var script_res: GDScript = load("res://procedural_generator.gd")
	var gen = script_res.new(Vector3i(48, 48, 48), Vector3i(8, 2, 38))
	for i in range(31):
		for j in range(31):
			var is_light: int = 1 if (j % 10 != 0) else 0
			gen.set_voxel(Vector3i(j, i, -30), is_light + 1, Vector3(1.0, 1.0, 1.0))
			var color_val := maxi(i, j)
			if color_val % 2 == 0:
				var c := Vector3(
					float((color_val % 3) / 2) * 0.5 + 0.5,
					float(((color_val + 1) % 3) / 2) * 0.5 + 0.5,
					float(((color_val + 2) % 3) / 2) * 0.5 + 0.5
				)
				gen.set_voxel(Vector3i(0, i, j - 30), 1, c)

	for i in range(31):
		for j in range(31):
			var c_val := (i + j) % 2
			var col := Vector3(float(c_val) * 0.3 + 0.3, float(1 - c_val) * 0.8 + 0.2, 1.0)
			gen.set_voxel(Vector3i(i, 0, j - 30), 1, col)

	return {
		"name": "Modern Art Wall (Taichi Ex. 2)",
		"type": "procedural",
		"size": gen.grid_size,
		"solid_count": gen.solid_count,
		"palette": [],
		"voxel_data": gen.data,
		"is_studio": true,
		"floor_y": 1.98,
		"custom_floor": Vector3(0.5, 0.5, 1.0),
		"use_custom_floor": true,
		"sun_angle": 5.90,
		"sun_elevation": 0.55,
		"sun_intensity": 2.0,
		"ambient_light": 0.28,
		"edge_darken": 0.0,
		"exposure": 1.70,
		"saturation": 1.15,
		"contrast": 1.05,
		"gamma": 2.20,
		"light_spread": 0.18,
		"enable_gi": true,
		"camera_target": Vector3(23.0, 17.0, 23.0),
		"camera_yaw": 0.72,
		"camera_pitch": -0.38,
		"camera_distance": 68.0,
		"camera_fov": 42.0
	}


# =========================================================================
# Taichi Voxel Challenge: Example 3 (Cornell Box)
# =========================================================================
static func generate_cornell_box() -> Dictionary:
	var script_res: GDScript = load("res://procedural_generator.gd")
	var gen = script_res.new(Vector3i(64, 64, 64), Vector3i(7, 2, 7))
	var n := 50
	for i in range(n):
		for j in range(n):
			gen.set_voxel(Vector3i(0, i, j), 1, Vector3(0.9, 0.3, 0.3))      # Left red wall
			gen.set_voxel(Vector3i(n, i, j), 1, Vector3(0.3, 0.9, 0.3))      # Right green wall
			gen.set_voxel(Vector3i(i, n, j), 1, Vector3(1.0, 1.0, 1.0))      # White ceiling
			gen.set_voxel(Vector3i(i, 0, j), 1, Vector3(1.0, 1.0, 1.0))      # White floor
			gen.set_voxel(Vector3i(i, j, 0), 1, Vector3(1.0, 1.0, 1.0))      # White back wall

	# Square ceiling light (mat = 2, white)
	var q := int(n / 8)
	for i in range(-q, q):
		for j in range(-q, q):
			gen.set_voxel(Vector3i(i + n / 2, n - 1, j + n / 2), 2, Vector3(1.0, 1.0, 1.0))

	# Interior sculpture
	var i_max := int(float(n) / 8.0 * 3.0)
	var j_max := int(float(n) / 4.0 * 3.0)
	for i_ in range(i_max):
		var i := i_ * 2
		for j in range(j_max):
			var y_sculp := int(float(n) / 4.0 + sin(float(i + j) / float(n) * 30.0) * 0.05 * float(n) + float(i) / 10.0)
			var z_sculp := -i + int(float(n) / 8.0 * 7.0)
			gen.set_voxel(Vector3i(j + int(n / 8), y_sculp, z_sculp), 1, Vector3(0.3, 0.3, 0.9))

	return {
		"name": "Cornell Box (Taichi Ex. 3)",
		"type": "procedural",
		"size": gen.grid_size,
		"solid_count": gen.solid_count,
		"palette": [],
		"voxel_data": gen.data,
		"is_studio": false,
		"floor_y": 1.95,
		"custom_floor": Vector3(1.0, 1.0, 1.0),
		"use_custom_floor": true,
		"custom_bg": Vector3(0.01, 0.01, 0.01),
		"use_custom_bg": true,
		"sun_intensity": 0.0,
		"ambient_light": 0.08,
		"edge_darken": 0.0,
		"exposure": 2.80,
		"saturation": 1.20,
		"contrast": 1.08,
		"gamma": 2.20,
		"light_spread": 0.15,
		"enable_gi": true,
		"camera_target": Vector3(32.0, 27.0, 32.0),
		"camera_yaw": 0.0,
		"camera_pitch": 0.0,
		"camera_distance": 76.0,
		"camera_fov": 45.0
	}


# =========================================================================
# Taichi Voxel Challenge: Example 4 (Cosmic Red Sphere)
# =========================================================================
static func generate_cosmic_sphere() -> Dictionary:
	var script_res: GDScript = load("res://procedural_generator.gd")
	var gen = script_res.new(Vector3i(128, 128, 128), Vector3i(64, 64, 64))
	var n := 60
	var r_sq := float(n * n) * 0.5
	for i in range(-45, 45):
		for j in range(-45, 45):
			for k in range(-45, 45):
				if float(i * i + j * j + k * k) < r_sq:
					gen.set_voxel(Vector3i(i, j, k), 1, Vector3(0.9, 0.3, 0.3))

	return {
		"name": "Cosmic Red Sphere (Taichi Ex. 4)",
		"type": "procedural",
		"size": gen.grid_size,
		"solid_count": gen.solid_count,
		"palette": [],
		"voxel_data": gen.data,
		"is_studio": false,
		"floor_y": -100.0,
		"custom_bg": Vector3(0.3, 0.4, 0.6),
		"use_custom_bg": true,
		"sun_angle": 5.80,
		"sun_elevation": 0.60,
		"sun_intensity": 2.20,
		"ambient_light": 0.35,
		"edge_darken": 0.0,
		"exposure": 1.30,
		"saturation": 1.15,
		"contrast": 1.05,
		"gamma": 2.20,
		"light_spread": 0.18,
		"enable_gi": true,
		"camera_target": Vector3(64.0, 64.0, 64.0),
		"camera_yaw": 0.65,
		"camera_pitch": -0.32,
		"camera_distance": 135.0,
		"camera_fov": 40.0
	}


# =========================================================================
# Taichi Voxel Challenge: Example 5 (Cloud City at Night)
# =========================================================================
static func generate_cloud_city(seed_val: int = 42) -> Dictionary:
	seed(seed_val)
	var script_res: GDScript = load("res://procedural_generator.gd")
	var gen = script_res.new(Vector3i(130, 130, 130), Vector3i(65, 65, 65))
	var n := 60
	var base := -24
	for i in range(-n, n):
		for j in range(-n, n):
			var dis := pow(maxf(0.0, 1.0 - Vector2(float(i), float(j)).length() / float(n)) * 1.1, 3.0)
			var height := randf() * float(n) * dis
			var k_min := int(-height * 0.6 + float(base))
			var k_max := int(height * 1.2 + float(base))
			for k in range(k_min, k_max):
				if k > base and dis * 0.1 > randf():
					var emit_col := Vector3(242.0/255.0, 239.0/255.0, 193.0/255.0).lerp(Vector3(236.0/255.0, 195.0/255.0, 107.0/255.0), randf())
					gen.set_voxel(Vector3i(i, k, j), 2, emit_col)
				else:
					var g := (1.0 - 0.8 * pow(dis, 0.6))
					gen.set_voxel(Vector3i(i, k, j), 1, Vector3(g, g, g))

	var tiny_clouds := [
		{"pos": Vector3i(30, -30, -20), "s": Vector3(2, 1, 2), "r1": 20.0, "r2": 40.0, "density": 0.3, "gray": 120.0/255.0},
		{"pos": Vector3i(20, -28, 24), "s": Vector3(2, 1, 2), "r1": 10.0, "r2": 30.0, "density": 0.4, "gray": 80.0/255.0},
		{"pos": Vector3i(-30, -32, 28), "s": Vector3(2, 1, 2), "r1": 10.0, "r2": 30.0, "density": 0.35, "gray": 80.0/255.0},
		{"pos": Vector3i(-40, -50, -34), "s": Vector3(3, 2, 3), "r1": 10.0, "r2": 30.0, "density": 0.2, "gray": 120.0/255.0},
		{"pos": Vector3i(36, -46, -36), "s": Vector3(2, 1, 2.4), "r1": 20.0, "r2": 50.0, "density": 0.3, "gray": 90.0/255.0}
	]
	for tc in tiny_clouds:
		var p: Vector3i = tc["pos"]
		var s: Vector3 = tc["s"]
		var r2: float = tc["r2"]
		var r1: float = tc["r1"]
		var dens: float = tc["density"]
		var g_val: float = tc["gray"]
		var ux := int(r2 * s.x)
		var uy := int(r2 * s.y)
		var uz := int(r2 * s.z)
		for ci in range(-ux, ux):
			for cj in range(-uy, uy):
				for ck in range(-uz, uz):
					var x_vec := Vector3(float(ci)/s.x, float(cj)/s.y, float(ck)/s.z)
					if x_vec.length_squared() < (r1 + (r2 - r1) * randf()) and randf() < dens:
						gen.set_voxel(p + Vector3i(ci, cj, ck), 1, Vector3(g_val, g_val, g_val))

	return {
		"name": "Cloud City at Night (Taichi Ex. 5)",
		"type": "procedural",
		"size": gen.grid_size,
		"solid_count": gen.solid_count,
		"palette": [],
		"voxel_data": gen.data,
		"is_studio": false,
		"floor_y": 0.98,
		"custom_floor": Vector3(0.01, 0.01, 0.015),
		"use_custom_floor": true,
		"custom_bg": Vector3(0.005, 0.005, 0.008),
		"use_custom_bg": true,
		"sun_angle": 5.80,
		"sun_elevation": 0.45,
		"sun_intensity": 1.20,
		"ambient_light": 0.15,
		"edge_darken": 0.0,
		"exposure": 1.40,
		"saturation": 1.25,
		"contrast": 1.15,
		"gamma": 2.20,
		"light_spread": 0.18,
		"enable_gi": true,
		"camera_target": Vector3(65.0, 52.0, 65.0),
		"camera_yaw": 0.82,
		"camera_pitch": -0.32,
		"camera_distance": 165.0,
		"camera_fov": 45.0
	}


# =========================================================================
# Taichi Voxel Challenge: Example 7 (Procedural City Grid)
# =========================================================================
static func _hash2d(p: Vector2) -> float:
	var st := p.dot(Vector2(12.9898, 78.233))
	return fposmod(sin(st) * 43758.5453, 1.0)


static func generate_city_grid(manual_seed: int = 77) -> Dictionary:
	seed(manual_seed)
	var script_res: GDScript = load("res://procedural_generator.gd")
	var gen = script_res.new(Vector3i(140, 96, 140), Vector3i(70, 10, 70))
	var lgrid := 15
	var ngrid := 8

	# 1. Road generation
	for _pass in range(manual_seed + 1):
		for ri in range(8):
			for rj in range(8):
				gen.set_voxel(Vector3i(ri, -8, rj), 0, Vector3.ZERO)
		var start := Vector2i(1 + int(randf() * float(ngrid - 2)), 1 + int(randf() * float(ngrid - 2)))
		var end_pt := Vector2i(1 + int(randf() * float(ngrid - 2)), 1 + int(randf() * float(ngrid - 2)))
		var turn := start + Vector2i(1, 1)
		while abs(turn.x - start.x) == 1 or abs(turn.y - start.y) == 1 or abs(turn.x - end_pt.x) == 1 or abs(turn.y - end_pt.y) == 1:
			turn = Vector2i(1 + int(randf() * float(ngrid - 2)), 1 + int(randf() * float(ngrid - 2)))

		for k in [0, 1]:
			var d := Vector2i(k, 1 - k)
			var p := Vector2i(start[k] * (1 - k), start[k] * k) - d
			while p[1 - k] < ngrid - 1:
				p += d
				gen.set_voxel(Vector3i(p.x, -8, p.y), 1, Vector3(0.5, 0.5, 0.5))
				if p[1 - k] == turn[1 - k]:
					d = (1 if start[k] < end_pt[k] else -1) * Vector2i(1 - k, k)
				if p[k] == end_pt[k]:
					d = Vector2i(k, 1 - k)

	# 2. Draw roads, buildings, and parks
	for xx in range(-60, 60):
		for zz in range(-60, 60):
			var ix := int((xx + 60) / lgrid)
			var iz := int((zz + 60) / lgrid)
			var uv := Vector2(float((xx + 60) % lgrid), float((zz + 60) % lgrid))

			var is_road_center: bool = (int(gen.get_voxel(Vector3i(ix, -8, iz))[0]) == 1)
			var d_up: int = 1 if (iz + 1 <= ngrid and int(gen.get_voxel(Vector3i(ix, -8, iz + 1))[0]) == 1) else 0
			var d_right: int = 1 if (ix + 1 < ngrid and int(gen.get_voxel(Vector3i(ix + 1, -8, iz))[0]) == 1) else 0
			var d_down: int = 1 if (iz - 1 >= 0 and int(gen.get_voxel(Vector3i(ix, -8, iz - 1))[0]) == 1) else 0
			var d_left: int = 1 if (ix - 1 >= 0 and int(gen.get_voxel(Vector3i(ix - 1, -8, iz))[0]) == 1) else 0

			var d_sum := d_up + d_right + d_down + d_left
			var r := _hash2d(Vector2(float(ix), float(iz)))
			if d_sum > 0:
				r = lerpf(r, 1.0, 0.4)

			if is_road_center:
				# Road pavement
				var is_mark: bool = (int(uv.x) == 7 and uv.y > 4.0 and uv.y < 12.0)
				gen.set_voxel(Vector3i(xx, 0, zz), 1, Vector3.ONE if is_mark else Vector3(0.5, 0.5, 0.5))
				# Sidewalk
				if uv.x <= 1.0 or uv.x >= 13.0:
					gen.set_voxel(Vector3i(xx, 1, zz), 1, Vector3(0.7, 0.65, 0.6))
				# Street lights
				if int(uv.y) == 7 and (int(uv.x) == 1 or int(uv.x) == 13):
					for li in range(2, 9):
						gen.set_voxel(Vector3i(xx, li, zz), 1, Vector3(0.6, 0.6, 0.6))
				if int(uv.y) == 7 and ((uv.x >= 1.0 and uv.x <= 2.0) or (uv.x >= 12.0 and uv.x <= 13.0)):
					gen.set_voxel(Vector3i(xx, 8, zz), 1, Vector3(0.6, 0.6, 0.6))
				if int(uv.y) == 7 and (int(uv.x) == 2 or int(uv.x) == 12):
					gen.set_voxel(Vector3i(xx, 7, zz), 2, Vector3(1.0, 1.0, 0.6))
			elif r > 0.5:
				# Building
				var br := 2.0 * r - 1.0
				var fl := int(3.0 + 10.0 * br)
				var wall := Vector3(_hash2d(Vector2(br, 1.0)), _hash2d(Vector2(br, 2.0)), _hash2d(Vector2(br, 2.0))) * 0.2 + Vector3(0.4, 0.4, 0.4)
				var maxdist := maxf(absf(uv.x - 7.0), absf(uv.y - 7.0))
				for bi in range(2, fl * 4):
					var is_window := (bi % 4 < 2)
					var light := Vector3(0.7, 0.7, 0.6) if (_hash2d(Vector2(_hash2d(Vector2(float(xx), float(zz))), float(bi / 2))) > 0.6) else Vector3(0.25, 0.35, 0.38)
					if maxdist < 6.0:
						if is_window:
							gen.set_voxel(Vector3i(xx, bi, zz), 1, light)
						else:
							gen.set_voxel(Vector3i(xx, bi, zz), 1, wall)
					if maxdist < 5.0:
						gen.set_voxel(Vector3i(xx, bi, zz), 2 if is_window else 1, light if is_window else wall)
				if maxdist == 5.0:
					for ri in range(fl * 4, fl * 4 + 2):
						gen.set_voxel(Vector3i(xx, ri, zz), 1, wall)
				for si in range(2):
					gen.set_voxel(Vector3i(xx, si, zz), 1, Vector3(0.7, 0.65, 0.6))
			else:
				# Park & greenery
				var pr := 2.0 * r
				var center := Vector2(float(int(_hash2d(Vector2(pr, 1.0)) * 7.0 + 4.0)), float(int(_hash2d(Vector2(pr, 2.0)) * 7.0 + 4.0)))
				var tree_h := 9 + int(_hash2d(Vector2(pr, 3.0))) * 5
				var to_c := (uv - center).length()
				for ti in range(tree_h + 3):
					if to_c < 1.0:
						gen.set_voxel(Vector3i(xx, ti, zz), 1, Vector3(0.36, 0.18, 0.06))
					if ti > mini(tree_h - 4, int((tree_h + 5) / 2)) and to_c < float(tree_h + 3 - ti) * (_hash2d(Vector2(pr, 4.0)) * 0.6 + 0.4):
						gen.set_voxel(Vector3i(xx, ti, zz), 1, Vector3(0.1, 0.35, 0.1))
				var gh := int(2.0 * sin((pow(uv.x, 2.0) + pow(uv.y, 2.0) + pow(_hash2d(Vector2(pr, 0.0)), 2.0) * 256.0) / 1024.0 * TAU) + 2.0)
				for gi in range(maxi(1, gh)):
					gen.set_voxel(Vector3i(xx, gi, zz), 1, Vector3(0.2, 0.55, 0.05))

	return {
		"name": "Procedural City Grid (Taichi Ex. 7)",
		"type": "procedural",
		"size": gen.grid_size,
		"solid_count": gen.solid_count,
		"palette": [],
		"voxel_data": gen.data,
		"is_studio": false,
		"floor_y": 0.95,
		"custom_floor": Vector3(1.0, 1.0, 1.0),
		"use_custom_floor": true,
		"custom_bg": Vector3(0.90, 0.98, 1.0),
		"use_custom_bg": true,
		"sun_angle": 5.75,
		"sun_elevation": 0.68,
		"sun_intensity": 2.10,
		"ambient_light": 0.32,
		"edge_darken": 0.0,
		"exposure": 1.50,
		"saturation": 1.20,
		"contrast": 1.08,
		"gamma": 2.20,
		"light_spread": 0.16,
		"enable_gi": true,
		"camera_target": Vector3(70.0, 24.0, 70.0),
		"camera_yaw": 0.75,
		"camera_pitch": -0.62,
		"camera_distance": 160.0,
		"camera_fov": 36.0
	}


# =========================================================================
# Taichi Voxel Challenge: Example 8 (The Great Ocean Wave & Moon)
# =========================================================================
static func _add_ocean_wave(gen: ProceduralGenerator, pos: Vector3i, radius: int, color: Vector3, portion: float, flipped: bool) -> void:
	var r_float := float(radius)
	var foam_col := Vector3(0.7, 0.8, 1.0)
	for dx in range(-radius, radius):
		for dy in range(-radius, radius):
			for dz in range(-radius, radius):
				var uv := Vector2(float(dx), float(dy)) / r_float
				var theta := atan2(uv.y, uv.x) / PI * 2.0
				var off_x := dx * (-1 if flipped else 1)
				var d_len := uv.length()
				if theta >= 0.0 and theta < portion:
					if absf(d_len - 0.95) < (0.05 + 0.05 * randf()):
						if (1.0 - pow(randf(), 2.0)) < (theta / portion - 0.1):
							gen.set_voxel(pos + Vector3i(off_x, dy, dz), 2, foam_col)
						else:
							gen.set_voxel(pos + Vector3i(off_x, dy, dz), 1, color)
				elif theta <= 0.0 and theta >= -1.0:
					if d_len > (0.90 - 0.05 * randf()):
						gen.set_voxel(pos + Vector3i(off_x, dy, dz), 1, color)


static func generate_ocean_waves(night_mode: bool = true) -> Dictionary:
	seed(42)
	var script_res: GDScript = load("res://procedural_generator.gd")
	var gen = script_res.new(Vector3i(140, 110, 140), Vector3i(70, 45, 70))
	var water_col := Vector3(0.2, 0.4, 1.0)
	var foam_col := Vector3(0.7, 0.8, 1.0)

	# 1. Ocean base with 3D sinusoidal undulating wave surface
	for ox in range(120):
		for oz in range(120):
			var t := (sin(float(ox) / 23.0 * PI) * sin(float(oz) / 27.0 * PI) + 1.0) * 0.5
			var r := randf()
			var h := (t - 0.1 * r) * 20.0 + (1.0 - t + 0.1 * r) * 10.0
			for oj in range(int(h)):
				var col_shade := (0.3 + 0.7 * float(oj) / maxf(h, 1.0)) * water_col
				gen.set_voxel(Vector3i(-60 + ox, -40 + oj, -60 + oz), 1, col_shade)
			if r < 0.02 and int(h) > 0:
				gen.set_voxel(Vector3i(-60 + ox, -40 + int(h) - 1, -60 + oz), 2, foam_col)

	# 2. Main curling waves
	_add_ocean_wave(gen, Vector3i(-20, 0, -20), 40, water_col, 1.0, true)
	_add_ocean_wave(gen, Vector3i(29, -5, 29), 30, water_col, 0.5, false)
	_add_ocean_wave(gen, Vector3i(-20, -15, 15), 20, water_col, 0.7, true)
	_add_ocean_wave(gen, Vector3i(-57, -15, 15), 20, water_col, 0.0, false)
	_add_ocean_wave(gen, Vector3i(20, -15, -39), 20, water_col, 0.56, false)
	_add_ocean_wave(gen, Vector3i(57, -15, -39), 20, water_col, 0.0, true)

	# 3. Glowing moon
	if night_mode:
		var moon_pos := Vector3i(40, 40, -40)
		var moon_r := 10
		for mi in range(-moon_r, moon_r):
			for mj in range(-moon_r, moon_r):
				for mk in range(-moon_r, moon_r):
					if Vector3(float(mi), float(mj), float(mk)).length() < float(moon_r):
						gen.set_voxel(moon_pos + Vector3i(mi, mj, mk), 2, Vector3(1.0, 1.0, 0.2))

	return {
		"name": "Ocean Waves & Moon (Taichi Ex. 8)",
		"type": "procedural",
		"size": gen.grid_size,
		"solid_count": gen.solid_count,
		"palette": [],
		"voxel_data": gen.data,
		"is_studio": false,
		"floor_y": 4.98,
		"custom_floor": Vector3(0.4, 0.6, 0.9),
		"use_custom_floor": true,
		"custom_bg": Vector3(0.08, 0.12, 0.18),
		"use_custom_bg": true,
		"sun_angle": 5.95,
		"sun_elevation": 0.52,
		"sun_intensity": 1.60,
		"ambient_light": 0.22,
		"edge_darken": 0.0,
		"exposure": 1.55,
		"saturation": 1.25,
		"contrast": 1.10,
		"gamma": 2.20,
		"light_spread": 0.18,
		"enable_gi": true,
		"camera_target": Vector3(70.0, 48.0, 70.0),
		"camera_yaw": 0.72,
		"camera_pitch": -0.40,
		"camera_distance": 175.0,
		"camera_fov": 38.0
	}


# =========================================================================
# Taichi Voxel Challenge: Example 9 (Cozy Bedroom Interior)
# =========================================================================
static func _stuff_bedroom(gen: ProceduralGenerator, p0: Vector3i, s: Vector3i, r: float) -> void:
	for x in range(s.x):
		var hy := int(roundf(float(s.y) - r * randf()))
		var hz := s.z - int(roundf(randf()))
		for y in range(maxi(1, hy)):
			for z in range(maxi(1, hz)):
				var a := randf()
				var col := Vector3(1.0, randf(), 0.0) if a < 0.4 else (Vector3(randf(), 1.0, 0.0) if a < 0.7 else Vector3(0.0, randf(), 1.0))
				gen.set_voxel(p0 + Vector3i(x, y, z), 1, col)


static func generate_cozy_bedroom() -> Dictionary:
	seed(42)
	var script_res: GDScript = load("res://procedural_generator.gd")
	var gen = script_res.new(Vector3i(140, 96, 140), Vector3i(70, 22, 70))
	var wood := Vector3(0.6, 0.5, 0.3)

	# 1. Room Shell (Back, Left, Right walls, Ceiling, Floor)
	gen.fill_block(Vector3i(-64, -20, -60), Vector3i(128, 74, 1), 1, Vector3(0.6, 0.6, 0.6))
	gen.fill_block(Vector3i(-64, -20, -60), Vector3i(1, 74, 120), 1, Vector3(0.6, 0.6, 0.6))
	gen.fill_block(Vector3i(63, -20, -60), Vector3i(1, 74, 120), 1, Vector3(0.6, 0.6, 0.6))
	gen.fill_block(Vector3i(-64, 53, -60), Vector3i(128, 1, 120), 1, Vector3(0.6, 0.6, 0.6))
	gen.fill_block(Vector3i(-64, -20, -60), Vector3i(128, 1, 120), 1, Vector3(0.2, 0.1, 0.0))

	# Ceiling light panel (mat = 2)
	for lx in range(0, 64):
		for lz in range(-60, 60):
			gen.set_voxel(Vector3i(lx, 52, lz), 2, Vector3(1.0, 0.85, 0.7))

	# Wall patterns
	for x in range(-64, 64):
		for y in range(-18, 54):
			var is_pat := (posmod(x, 9) == 1 or posmod(x, 9) == 7 or (absi(posmod(x, 9) - 4) + absi(posmod(y, 7) - 3)) == 1)
			gen.set_voxel(Vector3i(x, y, -60), 1, Vector3(0.5, 0.55, 0.6) if is_pat else Vector3(0.6, 0.6, 0.6))

	# Floor tiles
	for x in range(-64, 64):
		for z in range(-60, 60):
			var f_mult := 0.7 if (posmod(x, 4) == 0) else 1.0
			gen.set_voxel(Vector3i(x, -20, z), 1, Vector3(1.0, 0.7, 0.35) * f_mult)

	# Window cutout & curtains
	for x in range(-32, 0):
		for y in range(-4, 37):
			var v := randf()
			var c := Vector3.ONE if v < 0.7 else (Vector3(0.5, 1.0, 1.0) if v < 0.8 else (Vector3(1.0, 0.5, 1.0) if v < 0.9 else Vector3(1.0, 1.0, 0.5)))
			var is_c := ((posmod(x, 6) == 2 and posmod(y, 5) == 4) or (posmod(x, 6) == 3 and posmod(y, 5) == 3))
			var col := 0.65 * (c if is_c else Vector3(0.9, 0.6, 0.7))
			var z_off := -56 + int(roundf(sin(float(x) / 3.0 * PI)))
			gen.set_voxel(Vector3i(x, y, z_off), 1, col)

	# Carpet
	for x in range(-30, 0):
		for z in range(-22, 38):
			var max_d := maxi(absi(z - 8), -x)
			var col := Vector3.ONE if (max_d > 24 and max_d < 27) else Vector3(0.9, 0.6, 0.7)
			gen.set_voxel(Vector3i(x, -19, z), 1, col)

	# Desk & Chair
	gen.create_block(Vector3i(-33, -8, -50), Vector3i(24, 1, 14), wood, Vector3(0.05, 0.05, 0.05))
	gen.create_block(Vector3i(-32, -19, -49), Vector3i(22, 12, 12), wood, Vector3(0.05, 0.05, 0.05))
	gen.fill_block(Vector3i(-31, -19, -49), Vector3i(20, 9, 12), 0, Vector3.ZERO)
	_stuff_bedroom(gen, Vector3i(-30, -7, -48), Vector3i(7, 6, 6), 4.0)

	gen.create_block(Vector3i(-27, -19, -30), Vector3i(8, 14, 1), wood, Vector3(0.05, 0.05, 0.05))
	gen.create_block(Vector3i(-27, -19, -37), Vector3i(8, 6, 8), wood, Vector3(0.05, 0.05, 0.05))
	gen.fill_block(Vector3i(-27, -19, -36), Vector3i(8, 5, 6), 0, Vector3.ZERO)
	gen.fill_block(Vector3i(-26, -19, -37), Vector3i(6, 5, 8), 0, Vector3.ZERO)
	gen.create_block(Vector3i(-27, -13, -37), Vector3i(8, 1, 7), Vector3(0.5, 0.2, 0.3), Vector3(0.05, 0.05, 0.05))

	# Desk Lamp (Emissive)
	gen.create_block(Vector3i(-15, -7, -45), Vector3i(3, 1, 3), Vector3(0.2, 0.1, 0.1), Vector3.ZERO)
	gen.create_block(Vector3i(-14, -7, -44), Vector3i(1, 6, 1), Vector3(0.2, 0.1, 0.1), Vector3.ZERO)
	for ldx in range(-4, 5):
		for ldy in range(5):
			for ldz in range(-4, 5):
				if Vector3(float(ldx), float(ldy), float(ldz)).length() < 4.0:
					gen.set_voxel(Vector3i(-14 + ldx, -2 + ldy, -44 + ldz), 2, Vector3(1.0, 0.85, 0.7))

	# Bed
	gen.create_block(Vector3i(-62, -15, -56), Vector3i(26, 1, 76), wood, Vector3(0.05, 0.05, 0.05))
	gen.create_block(Vector3i(-61, -14, -56), Vector3i(24, 3, 76), Vector3.ONE, Vector3(0.05, 0.05, 0.05))
	gen.create_block(Vector3i(-56, -11, -54), Vector3i(14, 2, 9), Vector3.ONE, Vector3(0.05, 0.05, 0.05))
	gen.create_block(Vector3i(-62, -14, -36), Vector3i(26, 3, 52), Vector3(0.9, 0.6, 0.7), Vector3(0.05, 0.05, 0.05))

	# Potted Plant
	gen.create_block(Vector3i(-6, -4, -48), Vector3i(4, 4, 4), Vector3(0.5, 0.4, 0.3), Vector3.ZERO)
	gen.create_block(Vector3i(-5, 0, -47), Vector3i(2, 3, 2), Vector3(0.3, 0.6, 0.5), Vector3.ZERO)
	for px in range(6):
		for py in range(4):
			for pz in range(6):
				if randf() < 0.2:
					gen.set_voxel(Vector3i(-7 + px, 3 + py, -49 + pz), 1, Vector3(0.3, 0.6, 0.5))

	# Bookshelf & Boxes
	gen.create_block(Vector3i(-53, 17, -59), Vector3i(10, 1, 9), Vector3.ONE, Vector3.ZERO)
	_stuff_bedroom(gen, Vector3i(-51, 18, -59), Vector3i(6, 5, 7), 3.0)

	return {
		"name": "Cozy Bedroom Interior (Taichi Ex. 9)",
		"type": "procedural",
		"size": gen.grid_size,
		"solid_count": gen.solid_count,
		"palette": [],
		"voxel_data": gen.data,
		"is_studio": false,
		"floor_y": 1.95,
		"custom_floor": Vector3(0.0, 0.0, 0.0),
		"use_custom_floor": true,
		"custom_bg": Vector3(0.8, 0.85, 0.9),
		"use_custom_bg": true,
		"sun_angle": 5.75,
		"sun_elevation": 0.55,
		"sun_intensity": 1.80,
		"ambient_light": 0.15,
		"edge_darken": 0.0,
		"exposure": 2.20,
		"saturation": 1.15,
		"contrast": 1.05,
		"gamma": 2.20,
		"light_spread": 0.15,
		"enable_gi": true,
		"camera_target": Vector3(45.0, 24.0, 45.0),
		"camera_yaw": 0.35,
		"camera_pitch": -0.25,
		"camera_distance": 70.0,
		"camera_fov": 52.0
	}
