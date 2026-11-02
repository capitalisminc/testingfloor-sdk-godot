# Contributing

Use synthetic examples and test fixtures. Keep credentials, customer or game details, private infrastructure, and local machine paths out of source, docs, logs, issues, and pull requests. See [AGENTS.md](AGENTS.md).

## Layout

- `addons/testing_floor/` is what games copy. `client.gd` holds the SDK's behavior and takes its clock, transport and recording source from outside, so tests can replace them. `testing_floor.gd` is the autoload that connects it to the engine. `recording.gd` parses and resolves the desktop app's handoff.
- `tests/` is not part of the addon. `project.godot` at the repository root exists only so the tests can run.

## Run the tests

With Godot 4.4 or later:

```sh
python3 scripts/run_tests.py --godot /path/to/godot
```

The script imports the project, runs `tests/run_tests.gd` headless, and fails on any failed check or Godot script error. It runs:

- **The shared scenarios** in `tests/contract/scenarios`, through `tests/scenario_runner.gd`, with a fake clock, a temporary telemetry directory and a fake collector.
- **Contract fields:** every request, event, `$tf` key, record name and SDK property the client sends is declared in `tests/contract/telemetry_contract.json`.
- **Client and engine tests** for behavior the scenarios do not cover.

No test sends telemetry. CI runs the same script on Godot 4.4.1.

## SDK contract

`tests/contract` is an unedited copy of the published [Testing Floor SDK contract](https://github.com/capitalisminc/testingfloor-sdk-contract), and `tests/contract-source.json` records the commit it came from. Refresh it with `python3 scripts/update_contract.py`, then run the tests. `--check` confirms the copy still matches its recorded commit, and `--from <folder>` tries an unpublished change. Never edit the copy to make a test pass. Fix the SDK, or have the contract changed where it is published and copy it again.

When changing identity, fields, defaults, limits, retry policy, or units, change the published contract first, with a scenario that shows it, then update the SDK and its tests. Keep `SDK_VERSION` in `client.gd`, `plugin.cfg` and the changelog together.
