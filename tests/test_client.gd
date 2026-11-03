extends RefCounted
## Client behavior the shared scenarios do not cover: event properties, delivery
## outcomes, session state, tracked objects and movement.


func test_reserved_names_are_refused_and_counted(check) -> void:
	var client: TestingFloorClient = check.client()
	check.equal(client.track("$TF_telemetry_complete"), false, "a reserved name in any casing is refused")
	check.equal(client.dropped_events, 1, "a refusal counts as dropped while collecting")
	check.equal(client.pending_count(), 0, "nothing is queued")
	check.equal(client.track("level_started"), true, "an ordinary name is accepted")


func test_properties_follow_the_property_rules(check) -> void:
	var client: TestingFloorClient = check.client()
	client.track("example", {"kept": 1, "ratio": 0.5, "name": &"forest", "flags": PackedStringArray(["a", "b"]),
		"counts": [1, 2], "gone": null, "$private": 1, "": 2, "nan": NAN, "vector": Vector3.ONE, "mixed": ["a", 1]})
	client.flush()
	var event: Dictionary = check.named("example")[0]
	check.equal(event.get("kept"), 1, "integers are kept")
	check.equal(event.get("name"), "forest", "a StringName is sent as a string")
	check.equal(event.get("flags"), ["a", "b"], "string arrays are copied")
	# JSON parsing turns every number into a float, so check the integers on the wire.
	check.truthy(check.bodies[-1].contains("\"counts\":[1,2]"), "integer arrays are sent as integers")
	for key in ["gone", "$private", "", "nan", "vector", "mixed"]:
		check.truthy(not event.has(key), "%s is dropped" % key)


func test_event_processor_runs_last(check) -> void:
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.context_provider = func() -> Dictionary: return {"game_level.id": "forest", "health": 3}
		client.event_processor = func(properties: Dictionary) -> Dictionary:
			properties.erase("health")
			properties["converted"] = true
			return properties)
	client.track("example", {"health": 9})
	client.flush()
	var event: Dictionary = check.named("example")[0]
	check.truthy(not event.has("health"), "the processor can remove a merged value")
	check.equal(event.get("converted"), true, "the processor can add a value")
	check.equal(event.get("game_level.id"), "forest", "context values reach the processor")


func test_server_errors_retry_invalid_batches_drop_and_rejected_keys_stop(check) -> void:
	var client: TestingFloorClient = check.client()
	check.status = 503
	client.track("first")
	client.flush()
	check.equal(client.pending_count(), 1, "a server error keeps the event")
	check.status = 400
	check.advance(client, 1000)
	check.equal(client.pending_count(), 0, "an invalid batch is dropped")
	check.equal(client.dropped_events, 1, "and counted")
	check.equal(check.named("first").size(), 2, "the event was sent twice")
	check.status = 401
	client.track("second")
	client.flush()
	check.equal(client.is_collecting(), false, "a rejected key stops collection")
	check.equal(client.collection_reason(), "collector_rejected", "with a reason")
	check.equal(client.track("third"), false, "later events are refused")


func test_full_queue_drops_the_newest_event(check) -> void:
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void: client.queue_max_events = 2)
	check.equal(client.track("one"), true, "first fits")
	check.equal(client.track("two"), true, "second fits")
	check.equal(client.track("three"), false, "third is refused")
	check.equal(client.dropped_events, 1, "the overflow is counted")


func test_missing_write_key_disables_collection(check) -> void:
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void: client.write_key = "")
	check.equal(client.is_collecting(), false, "no write key, no collection")
	check.equal(client.collection_reason(), "missing_configuration", "with a reason")
	check.equal(client.track_object("crate", func() -> Variant: return Vector3.ZERO), "", "object tracking is off too")


func test_ordinary_editor_play_stays_off(check) -> void:
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void: client.is_editor = true)
	check.equal(client.is_collecting(), false, "the editor does not collect without a recording")
	check.equal(client.collection_reason(), "editor_policy_disabled", "with a reason")
	var always: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.is_editor = true
		client.enable_in_editor = true)
	check.equal(always.is_collecting(), true, "enable_in_editor collects")


func test_state_changes_are_sent_once_and_removals_as_null(check) -> void:
	var values := {"difficulty": "hard", "lives": 3}
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.state_provider = func() -> Dictionary: return values)
	client.track("first")
	values["lives"] = 2
	values.erase("difficulty")
	client.track("second")
	client.flush()
	var states: Array = check.named("$tf_state")
	check.equal(states.size(), 2, "a keyframe, then one change")
	check.equal(states[0]["$tf"].get("keyframe"), true, "the first state record is a keyframe")
	check.equal(states[1].get("lives"), 2, "the change carries the new value")
	check.truthy(states[1].has("difficulty") and states[1].difficulty == null, "a removed key is sent as null")
	check.truthy(not states[1]["$tf"].has("keyframe"), "a change is not a keyframe")


func test_objects_get_ids_samples_and_removal_reasons(check) -> void:
	var position := [Vector3.ZERO]
	var node := Node3D.new()
	check.root.add_child(node)
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.context_provider = func() -> Dictionary: return {"game_level.id": "forest"})
	var crate := client.track_object("crate", func() -> Variant: return position[0])
	check.equal(crate, "crate#1", "an object without an id gets kind#n")
	var lost := client.track_object("crate", func() -> Variant: return null)
	var dog := client.track_node("dog", node, "dog")
	var named := client.track_object("lamp", func() -> Variant: return Vector3.ONE, "lamp")
	client.track("level_started")
	check.advance(client, 300)
	position[0] = Vector3(0.1, 0, 0)
	check.advance(client, 300)
	position[0] = Vector3(0.5, 0, 0)
	node.free()
	client.remove_object(named, "")
	check.advance(client, 300)
	client.flush()
	var records: Array = check.named("$tf_objects")
	var samples := []
	var removed := {}
	for record in records:
		for index in record.get("sample.id", []).size():
			samples.append([record["sample.id"][index], record["sample.x"][index]])
		for index in record.get("removed.id", []).size():
			removed[record["removed.id"][index]] = record["removed.reason"][index]
		check.truthy(record.get("game_level.id") == "forest" and not record.has("player.position.x"),
			"object records copy game_level.* only")
	check.truthy(samples.has([crate, 0.0]) and samples.has([crate, 0.5]) and not samples.has([crate, 0.1]),
		"samples are sent on registration and after moving 0.25 m: %s" % [samples])
	check.equal(removed.get(lost), "gone", "a source that returns null is gone")
	check.equal(removed.get(dog), "destroyed", "a freed node is destroyed")
	check.equal(removed.get(named), "removed", "a removal without a reason is removed")


func test_an_id_tracked_again_is_removed_once_then_starts_in_a_later_check(check) -> void:
	var client: TestingFloorClient = check.client()
	client.track_object("dog", func() -> Variant: return Vector3.ZERO, "dog")
	check.advance(client, 300)
	client.remove_object("dog", "level_unloaded")
	client.track_object("dog", func() -> Variant: return Vector3(5, 0, 0), "dog")
	for step in 4:
		check.advance(client, 300)
	client.flush()
	var removals := 0
	var removed_at := -1
	var resampled_at := -1
	var records: Array = check.named("$tf_objects")
	for index in records.size():
		var record: Dictionary = records[index]
		removals += record.get("removed.id", []).count("dog")
		if record.get("removed.id", []).has("dog"):
			removed_at = index
		var samples: Array = record.get("sample.id", [])
		if samples.has("dog") and record["sample.x"][samples.find("dog")] == 5.0 and resampled_at < 0:
			resampled_at = index
	check.equal(removals, 1, "the removal is sent once")
	check.truthy(removed_at >= 0 and resampled_at > removed_at, "the new object starts after the removal, in a later record")


func test_a_destroyed_object_is_reported_after_its_record_was_dropped(check) -> void:
	var node := Node3D.new()
	check.root.add_child(node)
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void: client.queue_max_events = 2)
	client.track_node("crate", node, "crate")
	check.advance(client, 300)
	client.track("fills_the_queue")
	node.free()
	check.advance(client, 300)
	check.truthy(client.dropped_events > 0, "the removal's record was dropped while the queue was full")
	for step in 6:
		client.flush()
		check.advance(client, 300)
	var removed := []
	for record in check.named("$tf_objects"):
		for index in record.get("removed.id", []).size():
			removed.append([record["removed.id"][index], record["removed.reason"][index]])
	check.equal(removed, [["crate", "destroyed"]], "the removal is sent once the queue has room")


func test_object_limit_ignores_further_registrations(check) -> void:
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void: client.max_tracked_objects = 1)
	check.truthy(not client.track_object("a", func() -> Variant: return Vector3.ZERO).is_empty(), "the first object is tracked")
	check.equal(client.track_object("b", func() -> Variant: return Vector3.ZERO), "", "the second is ignored")


func test_movement_starts_pings_and_stops(check) -> void:
	var player := [Vector3.ZERO]
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.movement_tracking = true
		client.activity_source = func() -> Dictionary: return {"player_position": player[0]})
	check.advance(client, 100)
	for step in 12:
		player[0] += Vector3(0.1, 0, 0)
		check.advance(client, 100)
	for idle in 4:
		check.advance(client, 100)
	client.flush()
	var reasons: Array = check.named("$tf_player_moved").map(func(event: Dictionary) -> String: return event["movement.reason"])
	check.equal(reasons.front() if not reasons.is_empty() else "", "start", "movement starts")
	check.truthy(reasons.has("ping"), "and pings while moving: %s" % [reasons])
	check.equal(reasons.back() if not reasons.is_empty() else "", "stop", "and stops")
	var stop: Dictionary = check.named("$tf_player_moved").back()
	check.truthy(absf(float(stop.get("movement.distance", 0.0)) - 1.2) < 0.001, "stop covers the whole run: %s" % stop.get("movement.distance"))


func test_default_movement_samples_a_jump_several_times(check) -> void:
	var player := [Vector3.ZERO]
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.activity_source = func() -> Dictionary: return {"player_position": player[0]})
	check.truthy(client.movement_tracking, "movement tracking is on by default")
	check.advance(client, 100)
	# A half-second jump, sampled by the game every 50 ms.
	for step in 10:
		player[0] = Vector3(step * 0.1, sin(step * PI / 9.0), 0)
		check.advance(client, 50)
	client.flush()
	# The start sample and the pings both land on the arc.
	var samples: Array = check.named("$tf_player_moved")
	check.truthy(samples.size() >= 3, "a jump gets several samples, not one: %d" % samples.size())


func test_standing_still_sends_no_movement(check) -> void:
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.movement_tracking = true
		client.movement_min_step = 0.0
		client.activity_source = func() -> Dictionary: return {"player_position": Vector3.ONE})
	for frame in 20:
		check.advance(client, 100)
	client.flush()
	check.equal(check.named("$tf_player_moved").size(), 0, "zero movement stays still, even with a zero threshold")


func test_teleport_breaks_the_path(check) -> void:
	var player := [Vector3.ZERO]
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.activity_source = func() -> Dictionary: return {"player_position": player[0]})
	var token := client.begin_teleport("respawn")
	player[0] = Vector3(10, 0, 0)
	check.advance(client, 500)
	client.end_teleport(token)
	client.flush()
	var teleport: Dictionary = check.named("$tf_player_teleported")[0]
	check.equal(teleport.get("teleport.kind"), "teleport", "kind")
	check.equal(teleport.get("teleport.reason"), "respawn", "reason")
	check.equal(teleport.get("teleport.end.position.x"), 10.0, "end position")
	check.truthy(absf(float(teleport.get("teleport.duration", 0.0)) - 0.5) < 0.001, "duration")


func test_a_game_test_can_collect_through_a_fake_transport(check) -> void:
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.is_automation = true
		client.is_editor = true
		client.write_key = "")
	check.equal(client.is_collecting(), false, "automation does not collect")
	var sent := []
	client.use_test_transport(func(body: String, done: Callable) -> void:
		sent.append(body)
		done.call(200))
	check.equal(client.track("smoke"), true, "a game's test can collect, even in the editor")
	client.flush()
	check.equal(sent.size(), 1, "through its fake transport")
	check.equal(check.bodies.size(), 0, "and not the normal one")


func test_output_space_aligns_events_objects_and_lengths(check) -> void:
	var transform := {"axes": [2, -1, 3], "scale": 2.0, "offset": Vector3(10, 20, 30)}
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.build_id = "example-build"
		client.coordinate_transform = transform
		client.activity_source = func() -> Dictionary: return {"player_position": Vector3(2, 1, 3), "camera_rotation": Quaternion.IDENTITY}
		client.event_processor = func(values: Dictionary) -> Dictionary:
			check.equal(values["player.position.x"], 12.0, "processor sees output space")
			return values)
	# Configuration is captured at start, so mutating the caller's dictionary cannot split one run's space.
	transform.scale = 50.0
	client.track_object("crate", func() -> Variant: return Vector3(2, 1, 3), "crate")
	client.track("example", {"custom.position.x": 99, "camera.ortho_width": 4})
	client.record_teleport(Vector3.ZERO, Vector3(3, 4, 0))
	check.advance(client, 10)
	client.flush()
	var event: Dictionary = check.named("example")[0]
	check.equal(event["$tf"].get("build_id"), "example-build", "opaque build identity is separate context")
	check.equal([event["player.position.x"], event["player.position.y"], event["player.position.z"]], [12.0, 16.0, 36.0], "known points use axes, scale and offset")
	check.equal([event["camera.up.x"], event["camera.up.y"], event["camera.up.z"]], [1.0, 0.0, 0.0], "directions use axes only")
	check.truthy(not event.has("camera.euler.x"), "native Euler angles do not cross spaces")
	check.equal(event["camera.ortho_width"], 8.0, "lengths use output units")
	check.equal(event["custom.position.x"], 99, "arbitrary properties are not guessed")
	check.equal(check.named("$tf_player_teleported")[0]["teleport.distance"], 10.0, "teleport distance uses output units")
	var objects: Dictionary = check.named("$tf_objects")[0]
	check.equal([objects["sample.x"][0], objects["sample.y"][0], objects["sample.z"][0]], [12.0, 16.0, 36.0], "objects and events align")
	check.equal(client.track("$tf_player_moved"), false, "games cannot impersonate reserved automatic events")
	check.equal(client.track("player_moved"), true, "legacy game-owned names remain usable")


func test_recording_only_waits_in_a_built_game_and_resumes_after_pause(check) -> void:
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void: client.collection_mode = "recording_only")
	check.equal(client.collection_reason(), "recording_required", "built games wait for a recording")
	check.equal(client.track("before"), false, "no pre-recording collection")
	check.equal(client.track_object("crate", func() -> Variant: return Vector3.ONE, "crate"), "crate", "objects register while dormant")
	var directory := OS.get_user_data_dir().path_join("recording-only-" + TestingFloorClient.new_uuid())
	DirAccess.make_dir_recursive_absolute(directory)
	check.recording = {"recording_uuid": "example-recording", "lease_version": 1, "telemetry_requested": true,
		"lease_expires_at_unix_ms": check.now_ms + 10000, "telemetry_directory": directory, "playtest_id": 42}
	check.advance(client, 300)
	check.equal(client.track("active"), true, "discovery continues while dormant")
	check.recording.telemetry_requested = false
	check.advance(client, 300)
	check.equal(client.track("paused"), false, "paused recording stops collection")
	check.recording.telemetry_requested = true
	check.advance(client, 300)
	check.equal(client.track("resumed"), true, "recording resumes collection")
	client.flush()
	check.truthy(not check.named("$tf_objects").is_empty(), "dormant object is sampled after attach")
	client.shutdown()
	for name in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	DirAccess.remove_absolute(directory)


func test_invalid_output_space_refuses_collection(check) -> void:
	for config in [{"axes": [1, 1, 3]}, {"scale": 0}, {"scale": INF}, {"offset": Vector3(INF, 0, 0)}]:
		var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void: client.coordinate_transform = config)
		check.equal(client.is_collecting(), false, "invalid space never emits mixed coordinates")


func test_built_game_reads_renewable_file_from_legacy_launch_directory(check) -> void:
	var directory := ProjectSettings.globalize_path("user://built-lease-" + str(Time.get_ticks_usec()))
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("recording-payload.json")
	var launch := JSON.stringify({"recording_uuid": "example-built-recording", "telemetry_directory": directory})
	var write := func(requested: bool, uuid: String = "example-built-recording") -> void:
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify({"recording_uuid": uuid, "telemetry_directory": directory,
			"lease_version": 1, "telemetry_requested": requested, "lease_expires_at_unix_ms": check.now_ms + 5000}))
		file.close()
	var client: TestingFloorClient = check.client(func(client: TestingFloorClient) -> void:
		client.collection_mode = "recording_only"
		client.recording_source = func(now: int) -> Dictionary: return TestingFloorRecording.resolve("", launch, 0, now))
	client.track_object("crate", func() -> Variant: return Vector3.ONE, "example-crate")
	check.equal(client.is_collecting(), false, "launch metadata alone cannot enable collection")
	write.call(true, "other-capture")
	check.advance(client, 250)
	check.equal(client.is_collecting(), false, "a different capture cannot renew this launch")
	write.call(true)
	check.advance(client, 250)
	check.equal(client.is_collecting(), true, "the real file activates a built game")
	client.flush()
	check.truthy(not check.named("$tf_objects").is_empty(), "dormant objects are sent on attachment")
	check.now_ms += 6000
	write.call(true)
	check.advance(client, 250)
	check.equal(client.is_collecting(), true, "file renewal survives the launch-time expiry")
	write.call(false)
	check.advance(client, 250)
	check.equal(client.is_collecting(), false, "a fresh paused lease requests no telemetry")
	write.call(true)
	check.advance(client, 250)
	check.equal(client.is_collecting(), true, "a resumed lease collects again")
	DirAccess.remove_absolute(path)
	check.advance(client, 250)
	check.equal(client.is_collecting(), true, "a missing file retains only the last observed lease")
	check.advance(client, 6000)
	check.equal(client.is_collecting(), false, "missing file cannot revive legacy launch metadata")
	write.call(true)
	check.advance(client, 250)
	check.equal(client.is_collecting(), true, "a renewed lease resumes after a missing file")
	var closed := FileAccess.open(directory.path_join("closed.json"), FileAccess.WRITE)
	closed.store_string(str(check.now_ms))
	closed.close()
	check.advance(client, 250)
	check.advance(client, 250)
	client.flush()
	check.equal(client.is_collecting(), false, "closure blocks collection")
	check.equal(check.named("$tf_telemetry_complete").size(), 1, "closure completes the Play run once")
	for name in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	DirAccess.remove_absolute(directory)
