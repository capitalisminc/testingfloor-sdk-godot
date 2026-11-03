# Changelog

## 0.3.0

- Add immutable build identity, recording-only collection in built games and an optional shared output coordinate space.
- Namespace automatic movement and teleport events under `$tf_`; game-owned legacy names remain accepted.


## 0.2.0 — 2026-11-02

The first release as its own SDK. Version 0.1.0 was a client built into an example game.

- Follow the shared Testing Floor SDK contract, and run its scenarios in the SDK's tests.
- Recording leases: in the editor, collect only while the desktop app records, suspend when a lease expires, resume on renewal, and attach a recording that starts during Play. A lease handoff wins over the launch argument, and a handoff older than 12 hours is ignored unless its lease is live.
- Attach a recording when the run cannot write its registration file, as in a sandboxed game, and write the run's status file.
- Send the completion marker when the game exits, not only when the recording closes, and report whether the recording was interrupted.
- Retry only network failures, 408, 429 and server errors. Drop a batch the collector calls invalid, and stop collecting when it rejects the write key.
- Refuse event names beginning with `$tf_`, in any casing, and drop properties that the contract does not allow.
- Send a profile ID and an installation ID as separate player IDs, and the contract's `$tf` context: engine, editor, OS family, BCP 47 locale, app version, device model and screen size.
- Teleport scopes, movement `start`, `ping` and `stop` with the contract's thresholds, and camera up, focus and orthographic width.
- Configure through `testing_floor/*` project settings, added by the editor plugin. The QR marker is off by default.
- `use_test_transport()` also permits editor collection, so a game's own test collects wherever it runs.
- Movement samples (`player_moved`) are on by default and come up to ten times a second, set by the new `testing_floor/movement_min_ping_interval`. They used to be off, and two a second once turned on, which drew a half-second jump as a straight line.
- `testing_floor/quit_after_delivery` makes closing the window wait up to two seconds for delivery. It is off by default because it turns off `SceneTree.auto_accept_quit`.
- An object tracked again under a removed object's ID sends the removal once, and its own first sample in a later check.
- A `destroyed` or `gone` removal waits until its record is queued, like one from `remove_object()`, so a full queue no longer loses it.
- The `quitting` signal fires on `quit()` and on a window close, before the session completes, so a game can track its last events.
