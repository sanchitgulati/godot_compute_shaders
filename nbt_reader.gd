class_name NBTReader
extends RefCounted

## Loads and parses Minecraft Structure (.nbt) files and converts them into 3D voxel color grids.

static var _color_palette: Dictionary = {}
static var _palette_loaded: bool = false


static func load_color_palette(csv_path: String = "res://colors.csv") -> void:
	if _palette_loaded and not _color_palette.is_empty():
		return
	
	_color_palette.clear()
	var file := FileAccess.open(csv_path, FileAccess.READ)
	if not file:
		push_warning("Could not open colors file: " + csv_path)
		_palette_loaded = true
		return

	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split(",")
		if parts.size() >= 2:
			var block_name := parts[0].strip_edges()
			var hex := parts[1].strip_edges()
			_color_palette[block_name] = Color(hex)
	
	_palette_loaded = true


static func get_block_color(block_name: String) -> Color:
	if not _palette_loaded:
		load_color_palette()

	if _color_palette.has(block_name):
		return _color_palette[block_name]

	# Procedural fallback color based on name hash
	var hash_val := absi(block_name.hash())
	var h := float(hash_val % 360) / 360.0
	var s := 0.45 + float((hash_val >> 8) % 40) / 100.0
	var v := 0.55 + float((hash_val >> 16) % 35) / 100.0
	return Color.from_hsv(h, s, v, 1.0)


## Parses an NBT file from path and returns a Dictionary:
## {
##   "size": Vector3i,
##   "voxel_data": PackedByteArray,
##   "solid_count": int,
##   "palette": Array[String],
##   "blocks_count": int
## }
static func load_nbt_structure(file_path: String) -> Dictionary:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if not file:
		push_error("Failed to open NBT file: " + file_path)
		return {}

	var raw_data := file.get_buffer(file.get_length())
	var uncompressed: PackedByteArray

	# Check gzip header: 0x1F, 0x8B
	if raw_data.size() >= 2 and raw_data[0] == 0x1F and raw_data[1] == 0x8B:
		uncompressed = raw_data.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	else:
		uncompressed = raw_data

	if uncompressed.is_empty():
		push_error("Failed to decompress NBT data from " + file_path)
		return {}

	var spb := StreamPeerBuffer.new()
	spb.data_array = uncompressed
	spb.big_endian = true

	var parsed := _parse_nbt(spb)
	if parsed.is_empty():
		push_error("Failed to parse NBT root tag in " + file_path)
		return {}

	# Extract size
	var raw_size: Array = parsed.get("size", [0, 0, 0])
	var size := Vector3i(int(raw_size[0]), int(raw_size[1]), int(raw_size[2]))
	if size.x <= 0 or size.y <= 0 or size.z <= 0:
		push_error("Invalid NBT structure size: " + str(size))
		return {}

	# Extract palette
	var raw_palette: Array = parsed.get("palette", [])
	var palette: Array[String] = []
	for p in raw_palette:
		if p is Dictionary and p.has("Name"):
			palette.append(String(p["Name"]))
		else:
			palette.append("minecraft:air")

	# Extract blocks
	var raw_blocks: Array = parsed.get("blocks", [])
	var total_voxels := size.x * size.y * size.z
	var voxel_data := PackedByteArray()
	voxel_data.resize(total_voxels * 4)
	voxel_data.fill(0)

	var solid_count := 0

	for b in raw_blocks:
		if not (b is Dictionary):
			continue
		var pos_arr: Array = b.get("pos", [])
		if pos_arr.size() < 3:
			continue
		var bx := int(pos_arr[0])
		var by := int(pos_arr[1])
		var bz := int(pos_arr[2])

		if bx < 0 or bx >= size.x or by < 0 or by >= size.y or bz < 0 or bz >= size.z:
			continue

		var state_idx := int(b.get("state", -1))
		if state_idx < 0 or state_idx >= palette.size():
			continue

		var block_name := palette[state_idx]
		if block_name == "minecraft:air" or block_name == "minecraft:cave_air":
			continue

		var col := get_block_color(block_name)
		if col.a <= 0.01:
			continue

		# Material Classification:
		# 1 = Solid diffuse
		# 2 = Light source / Emissive (lantern, torch, campfire, glowstone, sea_lantern, lava)
		# 3 = Water (reflective liquid)
		# 4 = Glass / Translucent
		# 5 = Metal (gold, iron, chain, bell)
		var mat_type: int = 1
		var lower_name := block_name.to_lower()
		if "lantern" in lower_name or "torch" in lower_name or "campfire" in lower_name or "glowstone" in lower_name or "lava" in lower_name or "fire" in lower_name or "sea_lantern" in lower_name:
			mat_type = 2
		elif "water" in lower_name:
			mat_type = 3
		elif "glass" in lower_name:
			mat_type = 4
		elif "bell" in lower_name or "chain" in lower_name or "gold" in lower_name or "iron" in lower_name:
			mat_type = 5

		var idx := (bx + by * size.x + bz * size.x * size.y) * 4
		voxel_data[idx + 0] = int(clamp(col.r * 255.0, 0, 255))
		voxel_data[idx + 1] = int(clamp(col.g * 255.0, 0, 255))
		voxel_data[idx + 2] = int(clamp(col.b * 255.0, 0, 255))
		voxel_data[idx + 3] = mat_type
		solid_count += 1

	return {
		"size": size,
		"voxel_data": voxel_data,
		"solid_count": solid_count,
		"palette": palette,
		"blocks_count": raw_blocks.size()
	}


static func _parse_nbt(spb: StreamPeerBuffer) -> Dictionary:
	if spb.get_available_bytes() < 3:
		return {}
	var root_type := spb.get_8()
	var name_len := spb.get_16()
	var _root_name := spb.get_utf8_string(name_len)
	return _read_tag_payload(spb, root_type)


static func _read_tag_payload(spb: StreamPeerBuffer, tag_type: int) -> Variant:
	match tag_type:
		1: # TAG_Byte
			return spb.get_8()
		2: # TAG_Short
			return spb.get_16()
		3: # TAG_Int
			return spb.get_32()
		4: # TAG_Long
			return spb.get_64()
		5: # TAG_Float
			return spb.get_float()
		6: # TAG_Double
			return spb.get_double()
		7: # TAG_Byte_Array
			var len := spb.get_32()
			if len <= 0:
				return PackedByteArray()
			return spb.get_data(len)[1]
		8: # TAG_String
			var len := spb.get_16()
			if len <= 0:
				return ""
			return spb.get_utf8_string(len)
		9: # TAG_List
			var sub_type := spb.get_8()
			var len := spb.get_32()
			var list := []
			for i in range(len):
				list.append(_read_tag_payload(spb, sub_type))
			return list
		10: # TAG_Compound
			var compound := {}
			while spb.get_available_bytes() > 0:
				var tt := spb.get_8()
				if tt == 0:
					break
				var nlen := spb.get_16()
				var name := spb.get_utf8_string(nlen)
				compound[name] = _read_tag_payload(spb, tt)
			return compound
		11: # TAG_Int_Array
			var len := spb.get_32()
			var arr := PackedInt32Array()
			for i in range(len):
				arr.append(spb.get_32())
			return arr
		12: # TAG_Long_Array
			var len := spb.get_32()
			var arr := PackedInt64Array()
			for i in range(len):
				arr.append(spb.get_64())
			return arr
		_:
			return null
