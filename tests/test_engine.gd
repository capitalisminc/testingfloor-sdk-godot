extends RefCounted
## The autoload's engine-facing pieces: platform names, locale tags, the QR marker and quitting.

const Autoload := preload("res://addons/testing_floor/testing_floor.gd")


func test_operating_system_families(check) -> void:
	check.equal(Autoload.operating_system_family("macOS"), "macOS", "macOS")
	check.equal(Autoload.operating_system_family("Windows"), "Windows", "Windows")
	check.equal(Autoload.operating_system_family("FreeBSD"), "Linux", "BSDs use the Linux family")
	check.equal(Autoload.operating_system_family("Web"), "Web", "Web")
	check.equal(Autoload.operating_system_family("Haiku"), "Haiku", "others keep their name")


func test_language_tags(check) -> void:
	check.equal(Autoload.language_tag("en_US"), "en-US", "language and region")
	check.equal(Autoload.language_tag("en"), "en", "language only")
	check.equal(Autoload.language_tag("zh_Hans_CN"), "zh-Hans-CN", "script and region")
	check.equal(Autoload.language_tag(""), "", "unknown is left out")


func test_qr_marker_is_inverted_with_a_quiet_zone(check) -> void:
	var image: Image = Autoload.qr_image("example-session", 1767225600000, 1, 1)
	check.truthy(image.get_width() > 21 and image.get_width() == image.get_height(), "a square QR image")
	check.equal(image.get_pixel(0, 0), Color.BLACK, "the quiet zone is dark when inverted")
	check.equal(image.get_pixel(4, 4), Color.WHITE, "the first finder module is light when inverted")


func test_a_window_close_lets_the_game_track_before_the_session_completes(check) -> void:
	var autoload: Node = Autoload.new()
	check.root.add_child(autoload)
	var bodies: Array[String] = []
	autoload.use_test_transport(func(body: String, done: Callable) -> void:
		bodies.append(body)
		done.call(200))
	autoload.quitting.connect(func() -> void: check.truthy(autoload.track("game_exited"), "the game can still track while quitting"))
	autoload.notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)
	check.equal(autoload.collection_reason(), "shutdown", "the window close completes the session")
	check.truthy(bodies.any(func(body: String) -> bool: return body.contains("\"game_exited\"")), "the game's last event was sent")
	autoload.queue_free()
