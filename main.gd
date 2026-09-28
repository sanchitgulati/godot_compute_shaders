extends Control

@onready var status_label: Label = $MarginContainer/VBoxContainer/StatusLabel
@onready var input_label: Label = $MarginContainer/VBoxContainer/InputLabel
@onready var output_label: Label = $MarginContainer/VBoxContainer/OutputLabel
@onready var rerun_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/RerunButton
@onready var quit_button: Button = $MarginContainer/VBoxContainer/HBoxContainer/QuitButton

func _ready() -> void:
	if rerun_button:
		rerun_button.pressed.connect(run_compute_shader)
	if quit_button:
		quit_button.pressed.connect(func(): get_tree().quit())
	
	run_compute_shader()


func run_compute_shader() -> bool:
	print("========================================")
	print("[Compute Shader] Starting test execution...")
	
	# 1. Create or get RenderingDevice
	var rd: RenderingDevice = RenderingServer.create_local_rendering_device()
	if not rd:
		rd = RenderingServer.get_rendering_device()
	
	if not rd:
		var err_msg := "ERROR: No RenderingDevice available. Ensure Forward+ or Mobile renderer is enabled."
		printerr(err_msg)
		if status_label:
			status_label.text = err_msg
			status_label.modulate = Color.RED
		return false

	# 2. Load GLSL compute shader
	var shader_file: RDShaderFile = load("res://compute_example.glsl")
	if not shader_file:
		var err_msg := "ERROR: Failed to load res://compute_example.glsl"
		printerr(err_msg)
		if status_label:
			status_label.text = err_msg
			status_label.modulate = Color.RED
		return false

	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	var compile_error := shader_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if compile_error != "":
		var err_msg := "Shader compile error: " + compile_error
		printerr(err_msg)
		if status_label:
			status_label.text = err_msg
			status_label.modulate = Color.RED
		return false

	var shader := rd.shader_create_from_spirv(shader_spirv)
	if not shader.is_valid():
		var err_msg := "ERROR: Failed to create shader from SPIR-V bytecode."
		printerr(err_msg)
		if status_label:
			status_label.text = err_msg
			status_label.modulate = Color.RED
		return false

	# 3. Prepare input data
	var input := PackedFloat32Array([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0])
	var input_bytes := input.to_byte_array()

	# 4. Create storage buffer
	var buffer := rd.storage_buffer_create(input_bytes.size(), input_bytes)

	# 5. Create uniform set
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(buffer)
	var uniform_set := rd.uniform_set_create([uniform], shader, 0)

	# 6. Create compute pipeline & dispatch
	var pipeline := rd.compute_pipeline_create(shader)
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	# local_size_x = 2 in shader, 5 workgroups * 2 invocations = 10 items
	rd.compute_list_dispatch(compute_list, 5, 1, 1)
	rd.compute_list_end()

	# 7. Submit to GPU and wait for completion
	rd.submit()
	rd.sync()

	# 8. Retrieve output results
	var output_bytes := rd.buffer_get_data(buffer)
	var output := output_bytes.to_float32_array()

	print("[Compute Shader] Input:  ", input)
	print("[Compute Shader] Output: ", output)

	# 9. Verify results
	var success := true
	if output.size() != input.size():
		success = false
	else:
		for i in range(input.size()):
			if not is_equal_approx(output[i], input[i] * 2.0):
				success = false
				break

	if success:
		print("[Compute Shader] TEST PASSED! All values were correctly doubled by GPU.")
		if status_label:
			status_label.text = "Status: PASSED (GPU Compute Shader Executed Successfully)"
			status_label.modulate = Color.GREEN
	else:
		printerr("[Compute Shader] TEST FAILED! Output values did not match expected results.")
		if status_label:
			status_label.text = "Status: FAILED (Output did not match expected values)"
			status_label.modulate = Color.RED

	if input_label:
		input_label.text = "Input array:  " + str(input)
	if output_label:
		output_label.text = "Output array: " + str(output)

	# 10. Clean up RIDs
	rd.free_rid(pipeline)
	rd.free_rid(uniform_set)
	rd.free_rid(buffer)
	rd.free_rid(shader)

	print("========================================")
	return success
