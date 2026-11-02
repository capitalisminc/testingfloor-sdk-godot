extends RefCounted
## Runs the shared SDK scenarios in tests/contract/scenarios. The format is in
## tests/contract/scenarios/README.md. When a scenario fails, fix the SDK, or have
## the contract changed and copy it again. Never edit the copy to make a test pass.

const FOLDER := "res://tests/contract/scenarios"

## Set when the platform cannot provide what the scenario requires.
var skipped := ""
var problems: Array[String] = []


static func files() -> PackedStringArray:
	var names := PackedStringArray()
	for name in DirAccess.get_files_at(FOLDER):
		if name.ends_with(".json"):
			names.append(name)
	names.sort()
	return names


func run(root: Node, file: String) -> void:
	var scenario: Variant = JSON.parse_string(FileAccess.get_file_as_string(FOLDER.path_join(file)))
	if not scenario is Dictionary or int(scenario.get("format", 0)) != 1:
		problems.append("This runner reads scenario format 1 only")
		return
	match scenario.kind:
		"handoff":
			_run_handoff(scenario)
		"lifecycle":
			_run_lifecycle(root, scenario)
		_:
			problems.append("Unknown scenario kind %s" % scenario.kind)


func _run_handoff(scenario: Dictionary) -> void:
	var now := int(scenario.clock_unix_ms)
	for entry: Dictionary in scenario.cases:
		var recording := TestingFloorRecording.resolve(_payload_text(entry.get("sidecar")), _payload_text(entry.get("launch_argument")),
			int(entry.get("editor_process_id", 0)), now)
		var expect: Variant = entry.get("expect")
		if expect == null:
			if not recording.is_empty():
				problems.append("%s: picked %s, expected none" % [entry.name, recording.recording_uuid])
			continue
		if recording.is_empty():
			problems.append("%s: picked none, expected %s" % [entry.name, expect.recording_uuid])
			continue
		if recording.recording_uuid != expect.recording_uuid:
			problems.append("%s: picked %s" % [entry.name, recording.recording_uuid])
		if expect.has("playtest_id") and recording.playtest_id != (0 if expect.playtest_id == null else int(expect.playtest_id)):
			problems.append("%s: playtest_id is %d" % [entry.name, recording.playtest_id])
		if expect.has("suppress_qr") and recording.suppress_qr != expect.suppress_qr:
			problems.append("%s: suppress_qr is %s" % [entry.name, recording.suppress_qr])


func _run_lifecycle(root: Node, scenario: Dictionary) -> void:
	var directory := OS.get_user_data_dir().path_join("scenario-" + TestingFloorClient.new_uuid())
	DirAccess.make_dir_recursive_absolute(directory)
	if "unwritable_directory" in scenario.get("requires", []) and not _make_unwritable(directory):
		skipped = "this platform cannot make a directory unwritable"
		_remove(directory)
		return
	var editor: bool = scenario.environment == "editor"
	var manual: bool = scenario.collector == "manual"
	# Lambdas copy local values, so the shared state lives in one Dictionary.
	var world := {"ms": int(scenario.clock_start_unix_ms), "seconds": 0.0, "handoff": null, "bodies": [], "open": []}
	var client := TestingFloorClient.new()
	client.write_key = "test-only-never-transmitted"
	client.endpoint = "https://collector.invalid"
	# Records leave only on flush, shutdown, retries and the completion marker.
	client.flush_interval_seconds = 1.0e9
	client.is_editor = editor
	var settings: Dictionary = scenario.get("settings", {})
	client.queue_max_events = int(settings.get("queue_max_events", client.queue_max_events))
	client.enable_in_editor = settings.get("enable_in_editor", client.enable_in_editor)
	client.enable_in_editor_while_recording = settings.get("enable_in_editor_while_recording", client.enable_in_editor_while_recording)
	client.clock_ms = func() -> int: return world.ms
	client.transport = func(body: String, done: Callable) -> void:
		world.bodies.append(body)
		if manual:
			world.open.append(done)
		else:
			done.call(200)
	# Handoffs reach the client through the same resolution the autoload uses.
	client.recording_source = func(now_ms: int) -> Dictionary:
		if world.handoff == null:
			return {}
		return TestingFloorRecording.resolve(world.handoff if editor else "", "" if editor else world.handoff, 0, now_ms)
	root.add_child(client)
	var substituted := func(text: String) -> String:
		text = text.replace("{telemetry_directory}", directory.json_escape())
		return text.replace("{play_session_id}", client.play_session_id)
	var started := false
	for step: Dictionary in scenario.steps:
		var action := ""
		for key in step:
			if key != "accepted":
				action = key
		var value: Variant = step[action]
		if not started and not action in ["handoff", "start", "advance_ms", "create_file"]:
			problems.append("Step %s comes before start" % action)
			break
		match action:
			"handoff":
				world.handoff = null if value == null else substituted.call(_payload_text(value))
			"start":
				client.start(world.seconds)
				started = true
			"advance_ms":
				world.ms += int(value)
				world.seconds += float(value) / 1000.0
			"create_file":
				# The desktop app can always write in its own directory.
				_set_writable(directory, true)
				var file := FileAccess.open(directory.path_join(value), FileAccess.WRITE)
				file.store_string("{}")
				file.close()
			"track":
				var accepted := client.track(value)
				if step.has("accepted") and accepted != step.accepted:
					problems.append("track %s accepted %s" % [value, accepted])
			"poll":
				client.tick(world.seconds)
			"flush":
				client.flush()
			"respond":
				if world.open.is_empty():
					problems.append("respond %d: no request is waiting for an answer" % int(value))
					break
				var done: Callable = world.open.pop_front()
				done.call(int(value))
			"shutdown":
				client.shutdown()
				for attempt in 50:
					if client.pending_count() == 0 or not world.open.is_empty():
						break
					client.tick(world.seconds)
			"check":
				_check(client, value, directory, substituted)
			_:
				problems.append("Unknown step %s" % action)
	_compare(scenario.expect, world.bodies, substituted)
	client.queue_free()
	_set_writable(directory, true)
	_remove(directory)


func _check(client: TestingFloorClient, expected: Dictionary, directory: String, substituted: Callable) -> void:
	if expected.has("collecting") and client.is_collecting() != expected.collecting:
		problems.append("check collecting is %s" % client.is_collecting())
	if expected.has("recording_uuid"):
		var attached: String = client.get_recording().get("recording_uuid", "")
		var want: String = "" if expected.recording_uuid == null else expected.recording_uuid
		if attached != want:
			problems.append("check recording_uuid is %s, expected %s" % [attached, want])
	for name in expected.get("files_exist", []):
		if not FileAccess.file_exists(directory.path_join(substituted.call(name))):
			problems.append("check file exists: %s" % name)
	for name in expected.get("files_absent", []):
		if FileAccess.file_exists(directory.path_join(substituted.call(name))):
			problems.append("check file absent: %s" % name)
	if expected.has("status"):
		var path := directory.path_join(client.play_session_id + ".status.json")
		var status: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		_match(status if status is Dictionary else {}, expected.status, "status", substituted)


## Every expected field must match. A null expectation means the field is absent, not present as JSON null.
func _match(actual: Dictionary, expected: Dictionary, path: String, substituted: Callable) -> void:
	for key in expected:
		var name := "%s.%s" % [path, key]
		var want: Variant = expected[key]
		if want == null:
			if actual.has(key):
				problems.append("%s should be absent, but is %s" % [name, JSON.stringify(actual[key])])
		elif not actual.has(key):
			problems.append("%s is missing" % name)
		elif want is Dictionary:
			_match(actual[key] if actual[key] is Dictionary else {}, want, name, substituted)
		elif not _same(actual[key], want, substituted):
			problems.append("%s is %s, expected %s" % [name, JSON.stringify(actual[key]), JSON.stringify(want)])


static func _same(actual: Variant, want: Variant, substituted: Callable) -> bool:
	if want is String:
		return actual is String and actual == substituted.call(want)
	if want is bool:
		return actual is bool and actual == want
	if want is float or want is int:
		return (actual is float or actual is int) and float(actual) == float(want)
	return false


func _compare(expect: Dictionary, bodies: Array, substituted: Callable) -> void:
	var expected_requests: Array = expect.get("requests", [])
	var expected_events: Array = expect.get("events", [])
	# Only the records a scenario names are compared.
	var named := {}
	for request in expected_requests:
		for event in request.events:
			named[event["$name"]] = true
	for event in expected_events:
		named[event["$name"]] = true
	var received: Array[Dictionary] = []
	for body in bodies:
		var all: Array = JSON.parse_string(body).events
		var kept := all.filter(func(event: Dictionary) -> bool: return named.has(event["$name"]))
		if not kept.is_empty():
			received.append({"all": all, "named": kept})
	if expect.has("events"):
		var events := []
		for request in received:
			events.append_array(request.named)
		_compare_events(events, expected_events, "events", substituted)
		return
	if received.size() != expected_requests.size():
		problems.append("received %d requests, expected %d: %s" % [received.size(), expected_requests.size(),
			" ".join(received.map(func(request: Dictionary) -> String: return _describe(request.all)))])
		return
	for index in received.size():
		var want: Dictionary = expected_requests[index]
		var where := "request %d" % (index + 1)
		_compare_events(received[index].named, want.events, where, substituted)
		if want.get("exclusive", false) and received[index].all.size() != want.events.size():
			problems.append("%s must hold only %d events, but held %s" % [where, want.events.size(), _describe(received[index].all)])
		if want.has("repeats"):
			var original: Array = received[int(want.repeats) - 1].named
			var same: bool = original.size() == received[index].named.size()
			for event in original.size():
				same = same and original[event]["$id"] == received[index].named[event]["$id"] \
					and original[event]["$time"] == received[index].named[event]["$time"]
			if not same:
				problems.append("%s does not repeat request %d with the same $id and $time" % [where, int(want.repeats)])


func _compare_events(actual: Array, expected: Array, where: String, substituted: Callable) -> void:
	if actual.size() != expected.size():
		problems.append("%s: received %s, expected %d events" % [where, _describe(actual), expected.size()])
		return
	for index in actual.size():
		_match(actual[index], expected[index], "%s event %d" % [where, index + 1], substituted)


static func _describe(events: Array) -> String:
	return "[" + ", ".join(events.map(func(event: Dictionary) -> String: return event["$name"])) + "]"


## A payload given as an object is passed as compact JSON; a string is passed as it is.
static func _payload_text(value: Variant) -> String:
	if value == null:
		return ""
	if value is String:
		return value
	return JSON.stringify(value, "", false, true)


static func _make_unwritable(directory: String) -> bool:
	if not OS.get_name() in ["macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		return false
	_set_writable(directory, false)
	var probe := FileAccess.open(directory.path_join("probe"), FileAccess.WRITE)
	if probe == null:
		return true
	probe.close()
	return false


static func _set_writable(directory: String, writable: bool) -> void:
	if OS.get_name() in ["macOS", "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD"]:
		OS.execute("chmod", ["755" if writable else "555", directory])


static func _remove(directory: String) -> void:
	for name in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(name))
	DirAccess.remove_absolute(directory)
