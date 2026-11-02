extends RefCounted
## Assertions for one test, and a client wired to fakes: a clock the test moves,
## a collector that records every request body, and no recording unless the
## test supplies one.

var problems: Array[String] = []
var root: Node
var now_ms := 1767225600000
var seconds := 0.0
var bodies: Array[String] = []
var status := 200
var recording := {}
var _clients: Array[TestingFloorClient] = []


func equal(actual: Variant, expected: Variant, label: String) -> void:
	if typeof(actual) != typeof(expected) and not ((actual is int or actual is float) and (expected is int or expected is float)):
		problems.append("%s: %s (%s), expected %s (%s)" % [label, actual, type_string(typeof(actual)), expected, type_string(typeof(expected))])
	elif actual != expected:
		problems.append("%s: %s, expected %s" % [label, actual, expected])


func truthy(condition: bool, label: String) -> void:
	if not condition:
		problems.append(label)


## A started client that collects like a built game and sends to this check's collector.
func client(configure: Callable = Callable()) -> TestingFloorClient:
	var client := TestingFloorClient.new()
	client.write_key = "test-only-never-transmitted"
	client.endpoint = "https://collector.invalid"
	client.flush_interval_seconds = 1.0e9
	client.clock_ms = func() -> int: return now_ms
	client.transport = func(body: String, done: Callable) -> void:
		bodies.append(body)
		done.call(status)
	client.recording_source = func(_now: int) -> Dictionary: return recording
	if configure.is_valid():
		configure.call(client)
	root.add_child(client)
	_clients.append(client)
	client.start(seconds)
	return client


func advance(client: TestingFloorClient, milliseconds: int) -> void:
	now_ms += milliseconds
	seconds += milliseconds / 1000.0
	client.tick(seconds)


## Every event sent so far, in order.
func events() -> Array:
	var all := []
	for body in bodies:
		all.append_array(JSON.parse_string(body).events)
	return all


func named(name: String) -> Array:
	return events().filter(func(event: Dictionary) -> bool: return event["$name"] == name)


func cleanup() -> void:
	for client in _clients:
		client.queue_free()
