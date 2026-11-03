# Testing Floor SDK for Godot

Send gameplay telemetry from a Godot 4.4+ game to [Testing Floor](https://testingfloor.com), and link it to playtest recordings made with the Testing Floor desktop app. It is a GDScript addon with no native code, so it runs on every platform Godot exports to, and C# projects can call it through the `TestingFloor` autoload.

The SDK follows the shared [Testing Floor SDK contract](https://github.com/capitalisminc/testingfloor-sdk-contract), like the Unity and Unreal SDKs.

## Install

1. Copy `addons/testing_floor` into your project's `addons/` folder.
2. Enable **Testing Floor** under **Project → Project Settings → Plugins**. This adds the `TestingFloor` autoload and the `testing_floor/*` project settings.
3. Set **testing_floor/write_key** to your game's telemetry key, or set the `TESTING_FLOOR_WRITE_KEY` environment variable when you launch the game. Without a key the SDK collects nothing.

## Send events

```gdscript
TestingFloor.track("level_started", {"game_level.id": "forest"})
TestingFloor.track("item_picked_up", {"item.id": "shovel"})
```

Property values can be strings, integers, finite floats, booleans, and arrays of strings or of integers. Nulls, empty keys, keys beginning with `$`, and other types such as `Vector3` are left out; use `TestingFloorClient.vector_properties("target.position", position)` for a position. Event names beginning with `$tf_` are reserved for the SDK's own records and are refused.

`track` returns `false` when the event was not queued, for example while collection is off.

### Context, state and activity

```gdscript
# Small values that describe each moment. Added to every event.
TestingFloor.context_provider = func(): return {"game_level.id": level.id, "player.health": player.health}

# Values that stay true until they change. Sent as session state when they change.
TestingFloor.state_provider = func(): return {"settings.difficulty": difficulty}
TestingFloor.set_state("items.found", 3)

# Player and camera. Their positions go on every event and feed heatmaps and paths.
TestingFloor.activity_source = func():
	var camera := get_viewport().get_camera_3d()
	return {
		"player_position": player.global_position,
		"camera_position": camera.global_position,
		"camera_rotation": camera.global_basis,
		"camera_fov": camera.fov,
		"viewport_size": get_viewport().get_visible_rect().size,
	}
```

For an orthographic camera, send `camera_ortho_width` instead of `camera_fov`. A strategy or sim camera can add `camera_focus`, the world point at the center of the view.

`TestingFloor.event_processor` runs last over each event's properties and can change or remove them, for example to convert coordinates.

### Tracked objects

```gdscript
var id := TestingFloor.track_node("companion", companion, "pinda")
TestingFloor.set_object_state(id, "mood", 8.0)
TestingFloor.remove_object(id, "level_unloaded")

TestingFloor.track_object("pickup", func(): return pickup.global_position if is_instance_valid(pickup) else null)
```

The SDK checks tracked objects 4 times a second and sends a position when an object has moved at least 0.25 m. A tracked node that is freed is removed as `destroyed`; a position source that returns `null` is removed as `gone`. At most 256 objects are tracked at once.

### Movement and teleports

The SDK sends `player_moved` events from the activity source's player and camera, up to ten times a second while they move, so a half-second jump gets several samples. The map draws player paths and position heatmaps from them. They stay hidden in event lists by default. Raise **testing_floor/movement_min_ping_interval** to send fewer, for example in a slow-moving game, or turn **testing_floor/movement_tracking** off. Without an activity source, nothing is sent.

Use teleports so a respawn or save load does not count as distance traveled:

```gdscript
TestingFloor.record_teleport(old_position, player.global_position, "respawn")

var token := TestingFloor.begin_teleport("door")
await fade_and_move()
TestingFloor.end_teleport(token)
```

## Coordinates

Positions are sent in Godot's native units: meters with Y up in 3D, pixels in 2D, where a `Vector2` is sent as X and Y with Z 0. The map plane for 3D games is X/Z. Camera field of view is vertical, Godot's default.

## Recordings

When the Testing Floor desktop app launches a build, it passes `--testing-floor=<JSON>`; Godot hands it to the game whether or not it comes after `--`. The SDK attaches every event to that recording, registers the run in the recording's telemetry folder, and sends a completion marker when the recording closes or the game exits.

Playing in the editor does not collect by default. With **testing_floor/enable_in_editor_while_recording** on, the default, the SDK collects in the editor only while the desktop app records it, through a handoff at `.godot/TestingFloor/recording-payload.json`. **testing_floor/enable_in_editor** collects during every editor run.

The `recording_changed` signal fires when a recording starts, pauses, resumes or closes. `TestingFloor.get_recording()` returns the attached recording, and `is_collecting()` and `collection_reason()` say whether, and why not, the SDK is collecting.

### QR marker

Without a desktop handoff, Testing Floor can match a video to telemetry through a small QR marker in the corner of the screen. Turn it on with **testing_floor/qr_heartbeats**, or with the `--forceqr` launch argument. It refreshes every 15 seconds and hides itself while the desktop app records the game.

## Quitting

Call `TestingFloor.quit()` instead of `get_tree().quit()` to complete the recording and wait up to two seconds for the last events. When the window is closed directly, the SDK completes the recording and starts the final send, but Godot may exit before it finishes. Turn on **testing_floor/quit_after_delivery** to make a window close wait for delivery too; it turns off `SceneTree.auto_accept_quit`, so leave it off if your game handles closing itself, and call `TestingFloor.quit()` from your own handler.

To send the game's own last events, such as how a session ended, connect to the `quitting` signal. It fires on `quit()` and on a window close, before the session completes:

```gdscript
TestingFloor.quitting.connect(func(): TestingFloor.track("game_exited"))
```

## Settings

| Project setting | Default | |
| --- | --- | --- |
| `testing_floor/write_key` | empty | The game's telemetry key. `TESTING_FLOOR_WRITE_KEY` overrides it. |
| `testing_floor/endpoint` | `https://dataentry.testingfloor.com` | |
| `testing_floor/enabled` | on | The master switch. |
| `testing_floor/enable_in_editor` | off | Collect during every editor run. |
| `testing_floor/enable_in_editor_while_recording` | on | Collect in the editor while the desktop app records it. |
| `testing_floor/app_version` | empty | Overrides `application/config/version`. |
| `testing_floor/movement_tracking` | on | Send `player_moved` events from the activity source. |
| `testing_floor/movement_min_ping_interval` | 0.1 | Seconds between movement samples while moving. |
| `testing_floor/object_checks_per_second` | 4 | 1 to 10. |
| `testing_floor/max_tracked_objects` | 256 | |
| `testing_floor/qr_heartbeats` | off | Show the QR marker. |
| `testing_floor/quit_after_delivery` | off | Wait for delivery when the window is closed. |

Collection is off in automated test runs: when Godot runs GUT or GdUnit4, or with `--tf-test` or `--testing-floor-automation`.

## Player IDs

The SDK generates a profile ID, sent as the player ID, and keeps it in `user://testing_floor/profile-id`, with the game's saved data. It also generates an installation ID, kept in this machine's settings folder under `TestingFloor/`. Set **testing_floor/user_id** or **testing_floor/device_id** to use your own.

## Delivery

Events are sent in batches of up to 50, every quarter second, one request at a time. Server errors and network failures are retried with the same event IDs, starting at one second and doubling to 30 seconds. At most 4,096 events wait at once; when that is full, new events are dropped and counted in `dropped_events`. Nothing is stored on disk, so events that have not been sent when the game exits are lost.

## License

MIT. See [LICENSE.md](LICENSE.md). The bundled QR encoder is MIT-licensed; see [addons/testing_floor/third_party/README.md](addons/testing_floor/third_party/README.md).


### Build identity, collection and coordinates

Set `testing_floor/build_id` to an immutable artifact ID supplied by your build pipeline. `app_version` remains the display version; reusing a display label does not make two artifacts identical. Upload the map with the same build ID.

Collection defaults to `always` in built games. Set `testing_floor/collection_mode` to `recording_only` to wait for an active recording in any host. Discovery continues while waiting, and pause or lease expiry stops collection. Existing editor controls still apply.

The optional `testing_floor/coordinate_transform` dictionary declares one output space for known event points, tracked objects, directions and length metrics. For example, `{ "axes": [2, -1, 3], "scale": 2.0, "offset": Vector3(10, 20, 30) }` maps native `(x,y,z)` to `(2y+10,-2x+20,2z+30)`. Axes must be a signed permutation of 1–3; scale must be positive and finite; offset must be a finite Vector3. Invalid configuration disables collection. Configuration is captured at start.

Object quantization and movement thresholds use native units before conversion. Directions only permute/sign axes, and camera Euler properties are omitted when conversion is active. Arbitrary game properties pass through; the event processor runs after conversion. Map bounds and units must describe the output space. Change the build ID when that space changes.

Automatic movement and teleport events use `$tf_player_moved` and `$tf_player_teleported`. Update filters that used the previous automatic names. Games may still send their own `player_moved` and `player_teleported`; public `track` rejects reserved `$tf_` names.

Built games use the launch argument's telemetry directory to read the desktop app's renewable `recording-payload.json`. The file must name the same recording UUID. After observing a renewable lease, a missing or unreadable file retains that lease only until expiry; it cannot revive the static launch hint. Paused leases keep renewing with `telemetry_requested:false`. Recording-only mode requires a desktop app version that publishes this file; older desktop apps cannot activate that mode in built games.
