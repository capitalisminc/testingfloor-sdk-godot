extends RefCounted
## Compares what the client sends with tests/contract/telemetry_contract.json:
## the request and event envelope, $tf keys, record names, tracked-object fields,
## the SDK's own properties and limits.

const CONTRACT := "res://tests/contract/telemetry_contract.json"


func test_everything_sent_uses_declared_names(check) -> void:
	var contract: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CONTRACT))
	var directory := OS.get_user_data_dir().path_join("contract-" + TestingFloorClient.new_uuid())
	DirAccess.make_dir_recursive_absolute(directory)
	check.recording = {"recording_uuid": "example-recording", "telemetry_directory": directory, "playtest_id": 42,
		"suppress_qr": true, "lease_version": 0, "telemetry_requested": false, "lease_expires_at_unix_ms": 0, "editor_pid": 0}
	var player := [Vector3.ZERO]
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.movement_tracking = true
		client.app_version = "1.2.3"
		client.engine_name = "Godot 4.4.1"
		client.os_name = "macOS"
		client.locale = "en-US"
		client.device_id = "example-device"
		client.user_id = "example-profile"
		client.screen_size = Vector2i(1920, 1080)
		client.state_provider = func() -> Dictionary: return {"difficulty": "hard"}
		client.activity_source = func() -> Dictionary:
			return {"player_position": player[0], "camera_position": Vector3(0, 5, 5), "camera_rotation": Quaternion.IDENTITY,
				"camera_fov": 75.0, "camera_focus": Vector3.ZERO, "viewport_size": Vector2i(1920, 1080)})
	client.track_object("crate", func() -> Variant: return player[0] + Vector3.ONE, "crate")
	for step in 10:
		player[0] += Vector3(0.2, 0, 0)
		check.advance(client, 100)
	client.record_teleport(Vector3.ZERO, Vector3(5, 0, 0), "respawn")
	client.track("level_started", {"game_level.id": "forest"})
	FileAccess.open(directory.path_join("closed.json"), FileAccess.WRITE).close()
	check.advance(client, 300)
	client.shutdown()
	for attempt in 10:
		check.advance(client, 10)

	var declared_events := _keys(contract.event_fields)
	var required: Array = contract.event_fields.filter(func(field: Dictionary) -> bool: return field.required).map(func(field: Dictionary) -> String: return field.key)
	var context_keys := _keys(contract.context_fields)
	var sdk_records := {}
	for record in contract.platform_records:
		if record.sent_by == "sdk" and record.status == "current":
			sdk_records[record.name] = _keys(record.get("fields", []))
	var object_fields := _keys(contract.tracked_object_fields)
	# Properties the SDK writes, plus ones the game passes through it, such as teleport.reason.
	var sdk_properties := _keys(contract.conventional_properties.filter(func(field: Dictionary) -> bool: return field.status == "current"))
	var sdk_events := _keys(contract.sdk_events, "name")
	var time := RegEx.create_from_string("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$")
	var seen := {}
	for body in check.bodies:
		var request: Dictionary = JSON.parse_string(body)
		check.equal(request.keys().filter(func(key: String) -> bool: return not key in _keys(contract.request_fields)), [], "request envelope")
		check.truthy(time.search(request["$sent_at"]) != null, "$sent_at format: %s" % request["$sent_at"])
		for event: Dictionary in request.events:
			var name: String = event["$name"]
			seen[name] = true
			for key in required:
				check.truthy(event.has(key), "%s has %s" % [name, key])
			for key in event:
				if key.begins_with("$"):
					check.truthy(key in declared_events, "%s: %s is a declared event field" % [name, key])
			check.equal(event["$schema"], 2.0, "%s $schema" % name)
			check.truthy(time.search(event["$time"]) != null, "%s $time format: %s" % [name, event["$time"]])
			for key in event["$tf"]:
				check.truthy(key in context_keys, "%s: $tf.%s is a declared context field" % [name, key])
			check.truthy(JSON.stringify(event).to_utf8_buffer().size() <= _limit(contract, "event_bytes"), "%s fits the event limit" % name)
			var properties: Array = event.keys().filter(func(key: String) -> bool: return not key.begins_with("$"))
			if name == "$tf_objects":
				for key in properties:
					check.truthy(key in object_fields or key.begins_with("game_level."), "$tf_objects field %s is declared" % key)
			elif name == "$tf_state":
				for key in properties:
					check.truthy(key == "difficulty" or key in sdk_properties, "$tf_state field %s is the game's or declared" % key)
			elif sdk_records.has(name):
				for key in properties:
					check.truthy(key in sdk_records[name], "%s field %s is declared" % [name, key])
			else:
				check.truthy(not name.begins_with("$"), "%s is a game or SDK event" % name)
				for key in properties:
					var sdk_owned: bool = key.begins_with("player.") or key.begins_with("camera.") or key.begins_with("movement.") or key.begins_with("teleport.")
					check.truthy(not sdk_owned or key in sdk_properties, "%s: SDK property %s is declared" % [name, key])
	for name in ["level_started", "$tf_state", "$tf_objects", "$tf_telemetry_complete"] + sdk_events:
		check.truthy(seen.has(name), "the session sent %s" % name)
	for name in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	DirAccess.remove_absolute(directory)


static func _keys(rows: Array, field := "key") -> Array:
	return rows.map(func(row: Dictionary) -> String: return row[field])


static func _limit(contract: Dictionary, key: String) -> int:
	for row in contract.limits:
		if row.key == key:
			return int(row.value)
	return 0
