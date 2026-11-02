extends SceneTree
## Runs the shared contract scenarios and the SDK's own tests, then exits with 0
## when everything passed. See CONTRIBUTING.md for the command.

const ScenarioRunner := preload("res://tests/scenario_runner.gd")
const Check := preload("res://tests/check.gd")
const SUITES := ["res://tests/test_client.gd", "res://tests/test_contract_fields.gd", "res://tests/test_engine.gd"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var failed := 0
	var passed := 0
	var skipped := 0
	for file in ScenarioRunner.files():
		var runner := ScenarioRunner.new()
		runner.run(root, file)
		await process_frame
		if not runner.skipped.is_empty():
			skipped += 1
			print("SKIP scenario %s: %s" % [file, runner.skipped])
		elif runner.problems.is_empty():
			passed += 1
			print("PASS scenario %s" % file)
		else:
			failed += 1
			print("FAIL scenario %s" % file)
			for problem in runner.problems:
				print("    " + problem)
	for path in SUITES:
		var suite: Object = load(path).new()
		for method in suite.get_method_list():
			if not str(method.name).begins_with("test_"):
				continue
			var check := Check.new()
			check.root = root
			suite.call(method.name, check)
			await process_frame
			check.cleanup()
			if check.problems.is_empty():
				passed += 1
				print("PASS %s.%s" % [path.get_file().get_basename(), method.name])
			else:
				failed += 1
				print("FAIL %s.%s" % [path.get_file().get_basename(), method.name])
				for problem in check.problems:
					print("    " + problem)
	print("%d passed, %d failed, %d skipped" % [passed, failed, skipped])
	quit(1 if failed > 0 else 0)
