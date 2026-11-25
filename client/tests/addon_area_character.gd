extends "res://tests/addon_test_base.gd"
## Add-on test sections: character.

func _character_api(api, node: Node, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
	const AddonCharacter := preload("res://scripts/addons/addon_character.gd")
	var watch = host.watch
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	var hears_bridge := func() -> bool: return Bridge.message_received.is_connected(watch._on_message) or Bridge.welcomed.is_connected(watch._on_welcome)

	# Nothing before use: add-ons running in a game, the camera taken and handed back above, and still
	# nothing watches.
	check(api._character == null and not watch.is_on() and not watch.is_processing() and not hears_bridge.call(),
		"1.7: add-ons running, api.character and mode_changed never read: nothing processes, nothing on the bridge")
	check(api.camera.mode() == "angled" and api.camera.player_mode() == "angled" and not watch.is_on(),
		"1.7: mode() reads without watching: %s" % api.camera.mode())

	# The game's nodes as api.character reads them: a real avatar, a real UiModel, the hand, the HUD.
	var plain = fake.avatar
	var input_before = fake.input
	var world_before = fake.world
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)  # the test moves it
	fake.avatar = me
	var model := UiModel.new()
	var hud := FakeHud.new()
	var ui := FakeCharUi.new()
	ui.model = model
	hud.ui = ui
	add_child(hud)
	fake.hud = hud
	var hand := FakeHand.new()
	add_child(hand)
	fake.input = hand
	var world := FakeWorld.new()
	world.protos.by_id = {12: {"name": "iron-ore"}}
	add_child(world)
	fake.world = world
	me.snap_to(Vector2(10, 5))
	var feed := func(msg: Dictionary) -> void:
		if str(msg["t"]) == "me":
			me.update_from(msg)  # main.gd's handler first, as in the game
		Bridge.message_received.emit(msg)

	# The mode alone: watching each frame, not the bridge.
	var modes := Recorder.new()
	other.camera.mode_changed.connect(func(m: String, b: String) -> void: modes.got.append([m, b]))
	check(watch.is_on() and watch.is_processing() and not hears_bridge.call(),
		"1.7: mode_changed read: the watch runs, but isn't on the bridge (nobody wants the character)")

	# First touch of api.character, by the other add-on alone: a read (or set_lift) starts nothing; a
	# handler connected through it does, by the frame's end; stopped, all off again.
	var gone_part = other.character
	other.character.set_lift(0.0)
	await get_tree().process_frame
	check(not hears_bridge.call() and not watch._char_apis.has(other), "1.7: api.character read and set_lift called, no handler: the watch stays off the bridge")
	other.character.respawned.connect(func() -> void: pass)
	await get_tree().process_frame
	check(hears_bridge.call(), "1.7: a handler connected through api.character: the watch hears the bridge")
	var other_cam = other.camera
	host.stop(disk)
	check(not watch.is_on() and not watch.is_processing() and not hears_bridge.call() and not model.inventory_changed.is_connected(watch._on_inventory),
		"1.7: its only add-on switched off: the watch stops and leaves the bridge and the model")
	check(other_cam._mode_changed.get_connections().is_empty() and not other_cam._mode_wanted,
		"1.7: and the add-on's mode_changed has no handlers left")
	gone_part.respawned.connect(func() -> void: pass)
	check(not watch._char_apis.has(other) and not watch.is_on(), "1.7: a stopped add-on's kept api.character: reading a signal starts nothing")
	host.start(disk)
	other = disk["object"]
	check(gone_part is AddonCharacter and other != null and other._character == null and not watch.is_on(), "1.7: started again: a new api, unwatched")

	# The fixture add-on reads both (watch()), the other add-on records everything.
	node.watch()
	var heard := Recorder.new()
	heard.hear(other.character, AddonCharacter.SIGNALS)
	other.camera.mode_changed.connect(func(m: String, b: String) -> void: modes.got.append([m, b]))
	await get_tree().process_frame
	check(watch.is_on() and hears_bridge.call() and model.inventory_changed.is_connected(watch._on_inventory) and model.guns_changed.is_connected(watch._on_guns),
		"1.7: read by two add-ons: on the bridge and the model's inventory and guns")

	# No character yet.
	check(not api.character.exists() and api.character.state().is_empty() and api.character.weapons().is_empty() and api.character.armor() == "" and api.character.held().is_empty(),
		"1.7: before any `me`: no character, {} and empty gear")

	# State from a fed `me`.
	feed.call({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 100, "w": 1, "hp": 250, "mhp": 250, "sd": 30, "msd": 50,
		"m": 40, "mx": 2816, "my": 1280, "sh": 1, "v": 0, "vs": 0, "q": 0})
	await get_tree().process_frame
	var st: Dictionary = api.character.state()
	check(api.character.exists() and int(st.get("unit", 0)) == 5 and st.get("position") == Vector3(10, 0, 5) and st.get("walking") == true
		and int(st.get("health", 0)) == 250 and int(st.get("max_health", 0)) == 250 and int(st.get("shield", 0)) == 30 and int(st.get("max_shield", 0)) == 50,
		"1.7: state(): unit, position (tiles, y 0), walking, health and shield from a `me`: %s" % [st])
	check(st.get("mining") == true and is_equal_approx(float(st.get("mining_progress", 0.0)), 0.4) and st.get("mining_at") == Vector3(11, 0, 5)
		and st.get("repairing") == false and st.get("repairing_at") == null and st.get("firing") == true and int(st.get("vehicle", -1)) == 0
		and st.get("dead") == false and st.get("in_hub") == false and st.get("riding") == false and st.get("body_visible") == true and st.get("on_shown_surface") == true,
		"1.7: mining, its progress and place, firing, alive, on foot, shown")
	check(st.keys().size() == 26 and heard.got.is_empty() and node.hurt == Vector2i.ZERO, "1.7: 26 keys; the first `me` fires nothing: %s" % [heard.got])
	# speed: 0.75 tiles in 5 ticks is 0.15 a tick (Factorio's running speed), against the facing negative.
	feed.call({"t": "me", "u": 5, "x": 2560 + 192, "y": 1280, "k": 105, "w": 1, "hp": 250, "mhp": 250, "sd": 30, "msd": 50, "v": 0})
	me._clock.tick = 102.5 + me._clock.gap * 2.0
	var ahead: float = api.character.state()["speed"]
	me.rotation.y = PI / 2.0  # facing west, moving east
	var back: float = api.character.state()["speed"]
	check(is_equal_approx(ahead, 0.15) and is_equal_approx(back, -0.15) and (api.character.state()["forward"] as Vector3).is_equal_approx(Vector3(-1, 0, 0)),
		"1.7: speed in tiles a tick, 0.15 running, negative backwards; forward as the body faces: %.3f %.3f" % [ahead, back])
	me.rotation.y = 0.0
	feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 106, "w": 0, "hp": 250, "mhp": 250, "sd": 30, "msd": 50, "rp": 1, "rx": 2816, "ry": 1536, "v": 0})
	st = api.character.state()
	check(st["repairing"] == true and st["repairing_at"] == Vector3(11, 0, 6) and st["mining"] == false and st["mining_at"] == null and st["walking"] == false and st["firing"] == false,
		"1.7: repairing and where; mining and firing over")

	# Gear: weapons, armour, the hand.
	model.set_guns(1, [["pistol", "firearm-magazine", 10, 7, 10], ["submachine-gun", "", 0, 0, 0], ["", "", 0]])
	var w: Dictionary = api.character.weapons()
	check(int(w.get("selected", 0)) == 1 and int(w.get("vehicle", -1)) == 0 and (w.get("slots", []) as Array).size() == 3
		and w["slots"][0] == {"gun": "pistol", "ammo": "firearm-magazine", "magazines": 10, "rounds": 7, "magazine_size": 10}
		and int(w["slots"][2]["rounds"]) == -1, "1.7: weapons(): the slots as the tool bar shows them: %s" % [w])
	model.handle({"t": "slots", "l": {"armor": [["heavy-armor", 1]]}})
	hand.cursor_item = "iron-plate"
	hand.cursor_quality = "rare"
	check(api.character.armor() == "heavy-armor" and api.character.held() == {"item": "iron-plate", "quality": "rare"},
		"1.7: armor() and held(): %s %s" % [api.character.armor(), api.character.held()])
	hand.cursor_item = ""
	check(api.character.held().is_empty() and heard.named("armor_changed").is_empty() and heard.named("gun_selected").is_empty(),
		"1.7: an empty hand {}; the first armour and guns fire nothing")
	model.handle({"t": "slots", "l": {"armor": [["modular-armor", 1]]}})
	model.handle({"t": "slots", "l": {"armor": [["modular-armor", 1]]}})
	check(heard.named("armor_changed") == [["armor_changed", "modular-armor"]], "1.7: armor_changed once for new armour, not for the same again: %s" % [heard.named("armor_changed")])
	model.set_guns(1, [["pistol", "firearm-magazine", 10, 6, 10], ["submachine-gun", "", 0, 0, 0], ["", "", 0]])
	model.set_guns(2, [["pistol", "firearm-magazine", 10, 6, 10], ["submachine-gun", "", 0, 0, 0], ["", "", 0]])
	check(heard.named("gun_selected") == [["gun_selected", 2, "submachine-gun"]], "1.7: gun_selected once when the slot changes, not on ammo counts: %s" % [heard.named("gun_selected")])
	model.set_guns(1, [["vehicle-machine-gun", "firearm-magazine", 5, 10, 10]], 7)
	check(heard.named("gun_selected").size() == 2 and heard.named("gun_selected")[1] == ["gun_selected", 1, "vehicle-machine-gun"] and int(api.character.weapons()["vehicle"]) == 7,
		"1.7: and when the list becomes a vehicle's, weapons() saying whose")

	# Shots and mining: message time.
	feed.call({"t": "shot", "u": 5, "g": "submachine-gun", "a": "firearm-magazine", "x": 2560, "y": 2560})
	feed.call({"t": "shot", "u": 9, "g": "pistol", "a": "firearm-magazine", "x": 0, "y": 0})
	check(heard.named("shot_fired") == [["shot_fired", "submachine-gun", "firearm-magazine", Vector3(10, 0, 10)]], "1.7: shot_fired for the character's own round only: %s" % [heard.named("shot_fired")])
	feed.call({"t": "mnd", "u": 0, "p": 12, "x": 2560, "y": 1792, "g": 0, "l": []})
	feed.call({"t": "mnd", "u": 0, "p": 0, "gi": 1, "x": 2816, "y": 1792, "g": 1, "l": []})
	check(heard.named("mined") == [["mined", "iron-ore", Vector3(10, 0, 7), false], ["mined", "item-on-ground", Vector3(11, 0, 7), true]],
		"1.7: mined, with the prototype or item-on-ground, and gone: %s" % [heard.named("mined")])

	# Damage: summed over a frame, none for health rising.
	feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 107, "hp": 240, "mhp": 250, "sd": 30, "msd": 50, "v": 0})
	await get_tree().process_frame
	feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 108, "hp": 240, "mhp": 250, "sd": 20, "msd": 50, "v": 0})
	await get_tree().process_frame
	feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 109, "hp": 245, "mhp": 250, "sd": 20, "msd": 50, "v": 0})
	await get_tree().process_frame
	for hp in [240, 235, 230]:
		feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 500 - hp, "hp": hp, "mhp": 250, "sd": 20, "msd": 50, "v": 0})
	await get_tree().process_frame
	check(heard.named("damaged") == [["damaged", 10, 0], ["damaged", 0, 10], ["damaged", 15, 0]] and node.hurt == Vector2i(25, 10),
		"1.7: damaged (10, 0), a shield's (0, 10), none healing, three `me`s in a frame one (15, 0): %s" % [heard.named("damaged")])

	# Vehicles: 0, 7, 7, 0.
	var in_car: Dictionary = {}
	for i in 3:
		var v: int = [7, 7, 0][i]
		feed.call({"t": "me", "u": 5, "x": 2752, "y": 1280, "k": 600 + i, "hp": 230, "mhp": 250, "sd": 20, "msd": 50, "v": v, "vs": 150})
		if v == 7:
			st = api.character.state()
			in_car = api.world.character()
	check(heard.named("vehicle_entered") == [["vehicle_entered", 7]] and heard.named("vehicle_left") == [["vehicle_left", 7]],
		"1.7: vehicle_entered and vehicle_left once each")
	check(int(st["vehicle"]) == 7 and is_equal_approx(float(st["vehicle_speed"]), 0.15) and st["body_visible"] == false and is_equal_approx(float(st["speed"]), 0.0),
		"1.7: in a vehicle: its unit and speed in tiles a tick, the body not shown, speed 0: %s" % [st])
	check(in_car.keys() == ["unit", "position", "forward", "vehicle", "visible"] and int(in_car["unit"]) == 5 and int(in_car["vehicle"]) == 7
		and in_car["position"] == st["position"] and in_car["forward"] == st["forward"] and in_car["visible"] == true,
		"1.7: api.world.character() unchanged: its five keys, the same values, `visible` the node's own flag (true in a vehicle): %s" % [in_car])

	# Hub, pod, first person, another surface, the remote view.
	fake.ride.hub = true
	check(api.character.state()["in_hub"] == true and api.character.state()["body_visible"] == false and api.character.exists(), "1.7: in a hub: in_hub, not shown, still there")
	fake.ride.hub = false
	fake.ride.on = true
	check(api.character.state()["riding"] == true and api.character.state()["body_visible"] == false, "1.7: riding a pod")
	fake.ride.on = false
	me.set_first_person(true)
	check(api.character.state()["body_visible"] == false, "1.7: first person: the body not shown")
	me.set_first_person(false)
	ui.viewing_si = 3
	check(api.character.state()["on_shown_surface"] == false, "1.7: another surface shown")
	ui.viewing_si = 0
	var before_remote: Dictionary = api.character.state()
	rig.in_remote = true
	check(api.character.state() == before_remote and api.camera.mode() == "remote", "1.7: the remote view leaves the state alone; mode() says remote")
	rig.in_remote = false
	await get_tree().process_frame

	# Steps: one run loop each way gives right then left; none between, none in a vehicle.
	if me._rig == null:
		check(false, "1.7: the character's rig loads for the footfall checks")
	else:
		var anim = me._anim
		var dt := 1.0 / 60.0
		for way: float in [1.0, -1.0]:
			anim._run_phase = TAU * (0.75 if way > 0.0 else 0.25)  # a quarter loop before the right foot's touch-down
			var start: int = anim.footfalls
			var frames := 0
			heard.got.clear()
			node.steps.clear()
			var guard := 0
			while anim.footfalls < start + 2 and guard < 3000:
				anim.running = true
				anim.step(me._pose, dt, way * 0.05)
				guard += 1
				if guard % 4 == 0:
					await get_tree().process_frame
					frames += 1
			await get_tree().process_frame
			await get_tree().process_frame
			var feet: Array = heard.named("footfall").map(func(e: Array) -> String: return e[1])
			check(feet == ["right", "left"] and node.steps == feet and (heard.named("footfall")[0][2] as Vector3) == me.global_position,
				"1.7: a run loop %s: two footfalls, right then left, where the body is: %s over %d frames" % ["forwards" if way > 0.0 else "backwards", feet, frames])
		check(is_equal_approx(float(api.character.state()["stride"]), anim._run_phase / TAU), "1.7: stride is the run loop's place")
		heard.got.clear()
		me.vehicle = 7
		var start2: int = anim.footfalls
		while anim.footfalls < start2 + 2:
			anim.step(me._pose, dt, 0.05)
		await get_tree().process_frame
		me.vehicle = 0
		check(heard.named("footfall").is_empty(), "1.7: no footfall in a vehicle")
		anim.running = false
		# Flight: one took_off, one landed.
		anim.flying = true
		anim.descending = false
		anim.flight_height = 1.0
		for i in 60:
			anim.step(me._pose, 0.05, 0.0)
		await get_tree().process_frame
		var up: Dictionary = api.character.state()
		anim.flying = false
		for i in 60:
			anim.step(me._pose, 0.05, 0.0)
		await get_tree().process_frame
		await get_tree().process_frame
		check(heard.named("took_off").size() == 1 and heard.named("landed").size() == 1 and up["flying"] == true and float(up["height"]) > 0.5
			and api.character.state()["flying"] == false, "1.7: took_off and landed once each, flying and height while up: %s" % [heard.got])

	# Death and respawn.
	heard.got.clear()
	ui.death_screen.left = 5.0
	ui.death_screen.died_at = Vector2(12, 6)
	feed.call({"t": "died", "u": 5, "p": 0, "x": 3072, "y": 1536})
	feed.call({"t": "dead", "left": 300, "x": 3072, "y": 1536})
	feed.call({"t": "dead", "left": 270, "x": 3072, "y": 1536})
	st = api.character.state()
	check(heard.named("died") == [["died", Vector3(12, 0, 6)]] and not api.character.exists() and st["dead"] == true and int(st["health"]) == 0
		and st["position"] == Vector3(12, 0, 6) and st["walking"] == false, "1.7: died once for a `died` and two `dead`s; dead: no character, health 0, where it died")
	me.heard_me = false  # main.gd's _on_welcome: the respawned character is a new one
	Bridge.welcomed.emit({"t": "welcome", "u": 6})
	ui.death_screen.left = -1.0
	ui.death_screen.died_at = null
	feed.call({"t": "me", "u": 6, "x": 0, "y": 0, "k": 900, "hp": 250, "mhp": 250, "v": 0})
	await get_tree().process_frame
	check(heard.named("respawned").size() == 1 and heard.named("damaged").is_empty() and api.character.exists() and int(api.character.state()["unit"]) == 6,
		"1.7: respawned on the new character's first `me`, nothing else: %s" % [heard.got])

	# Modes.
	modes.got.clear()
	node.modes.clear()
	rig.toggle_first_person()
	await get_tree().process_frame
	await get_tree().process_frame
	check(api.camera.mode() == "first_person" and modes.got == [["first_person", "angled"]] and node.modes == modes.got, "1.7: first person, mode_changed once to each add-on: %s" % [modes.got])
	rig.in_remote = true
	await get_tree().process_frame
	check(api.camera.mode() == "remote", "1.7: the remote view over first person is remote")
	rig.in_remote = false
	rig.toggle_first_person()
	await get_tree().process_frame
	rig.toggle_factorio_view()
	await get_tree().process_frame
	await get_tree().process_frame
	var in_f6: String = api.camera.mode()
	rig.zoom(1.5)
	await get_tree().process_frame
	check(in_f6 == "factorio" and api.camera.mode() == "angled", "1.7: Factorio's view, zoomed out of it angled again: %s %s" % [in_f6, api.camera.mode()])
	var count := modes.got.size()
	rig.toggle_projection()
	await get_tree().process_frame
	rig.toggle_projection()
	await get_tree().process_frame
	check(modes.got.size() == count and api.camera.mode() == "angled", "1.7: F7 changes no mode: %s" % [modes.got.slice(count)])
	rig.cinematic(30.0, 40.0)
	await get_tree().process_frame
	check(api.camera.mode() == "ride" and modes.got.back() == ["ride", "angled"], "1.7: a ride's film is ride")
	rig.cinematic_end()
	await get_tree().process_frame
	rig.toggle_first_person()
	await get_tree().process_frame
	check(other.camera.take(), "1.7: the other add-on takes the camera")
	await get_tree().process_frame
	check(api.camera.mode() == "addon" and other.camera.mode() == "addon" and api.camera.player_mode() == "first_person" and modes.got.back() == ["addon", "first_person"]
		and node.modes.back() == ["addon", "first_person"], "1.7: taken: addon for both, player_mode() the view under it, both told")
	other.camera.release()
	await get_tree().process_frame
	check(api.camera.mode() == "first_person" and modes.got.back() == ["first_person", "addon"], "1.7: released: back to first person")
	rig.vr_view = Node3D.new()
	check(api.camera.mode() == "vr" and api.camera.player_mode() == "vr", "1.7: a headset: vr")
	rig.vr_view.free()
	rig.vr_view = null
	rig.toggle_first_person()
	await get_tree().process_frame

	# Switched off with another add-on still listening.
	var still: int = node.steps.size()
	var stopped_cam = other.camera
	var stopped_part = other._character
	host.stop(disk)
	check(stopped_cam._mode_changed.get_connections().is_empty() and stopped_part._footfall.get_connections().is_empty()
		and stopped_part._damaged.get_connections().is_empty(), "1.7: switched off: the add-on's handlers are gone")
	check(watch.is_on() and hears_bridge.call(), "1.7: the other add-on still listening keeps the watch on")
	feed.call({"t": "me", "u": 6, "x": 0, "y": 0, "k": 901, "hp": 200, "mhp": 250, "v": 0})
	await get_tree().process_frame
	check(node.hurt == Vector2i(75, 10) and node.steps.size() == still, "1.7: and still hears its events: %s" % [node.hurt])
	host.start(disk)

	# A new game: no event for its first values, handlers still there.
	node.modes.clear()
	host.game_ended()
	check(not watch.is_on() and not hears_bridge.call(), "1.7: game over: the watch off the game")
	host.game_started()
	await get_tree().process_frame
	feed.call({"t": "me", "u": 6, "x": 0, "y": 0, "k": 902, "hp": 100, "mhp": 250, "v": 3})
	await get_tree().process_frame
	await get_tree().process_frame
	check(watch.is_on() and hears_bridge.call() and node.hurt == Vector2i(75, 10) and node.modes.is_empty() and api.character.exists()
		and not api.character._footfall.get_connections().is_empty(), "1.7: a new game: watched again, its first values fire nothing, handlers kept")

	# Back as the rest of the test had it.
	fake.avatar = plain
	fake.input = input_before
	fake.world = world_before
	fake.hud = null
	for n: Node in [me, hud, hand, world]:
		n.queue_free()
	await get_tree().process_frame


## API 1.7, step 3: api.character.set_lift, the drawn-only lift. The body, lantern, old flashlight, eye,
## view's centre, bar and fallback muzzle rise; the new flashlight only moves across; the game's place,
## reach and what the crosshair can pick don't move, and nothing is sent. Caps, two add-ons summed, undone
## on stop and at the game's end, suspended in a vehicle and dead, api.world.stand_height_at, the hills.


func _character_lift(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const CombatLayer := preload("res://scripts/world/combat.gd")
	const PlayerInput := preload("res://scripts/player/player_input.gd")
	const GroundHeight := preload("res://scripts/world/ground_height.gd")
	const AimPick := preload("res://scripts/world/aim_pick.gd")
	const Visuals := preload("res://scripts/world/visuals.gd")
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	var plain = fake.avatar
	var world_before = fake.world
	var target_before = rig.target
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)  # the test moves it: _process(0.0) draws a frame without moving or animating on
	fake.avatar = me
	rig.target = me
	host._push_lift()  # main.gd's avatar is there at game_started; this one came after
	me.snap_to(Vector2(10, 5))
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	var combat := CombatLayer.new()
	combat.avatar = me
	var draw := func() -> void:
		me._process(0.0)
		rig._process(0.0)
	var eye := func() -> Vector3:
		if not rig.first_person:
			rig.toggle_first_person()
		rig._process(0.0)
		var at: Vector3 = rig.camera.global_position
		rig.toggle_first_person()
		return at
	var has_rig: bool = me._rig != null
	check(has_rig, "lift: the character's rig loads (the pose checks need it)")
	draw.call()
	var root0: Vector3 = me._pose.root_offset if has_rig else Vector3.ZERO
	var pos0 := me.position
	var ground0 := me.ground_position()
	var lantern0 := me._lantern.global_position
	var beam0 := me._flashlight.global_position
	var focus0: Vector3 = rig._focus_goal()
	var eye0: Vector3 = eye.call()
	var bar0: Vector3 = combat._bar_position(5)
	me.set_first_person(true)
	var muzzle0 := me.muzzle_position()
	me.set_first_person(false)
	var world0: Dictionary = api.world.character()
	var state0: Dictionary = api.character.state()

	# Body and state: one tile up.
	api.character.set_lift(1.0)
	draw.call()
	var st: Dictionary = api.character.state()
	check(is_equal_approx(me.drawn_lift(), 1.0) and (not has_rig or me._pose.root_offset.is_equal_approx(root0 + Vector3(0, 1, 0)))
		and me.position == pos0 and me.ground_position() == ground0,
		"lift: set_lift(1): drawn_lift 1, the pose's root up 1, position and ground_position unchanged to the bit: %s" % [me._pose.root_offset if has_rig else "no rig"])
	check(is_equal_approx(float(st["height"]), 1.0) and st["lift"] == Vector3(0, 1, 0) and (st["position"] as Vector3).y == 0.0 and st["position"] == state0["position"]
		and api.world.character() == world0 and api.character.lift() == Vector3(0, 1, 0) and st.keys().size() == 26,
		"lift: state() height 1, lift (0, 1, 0), position the game's; api.world.character() unchanged: %s" % [st])

	# Lights: the lantern rises; the new flashlight (Factorio's picture from above) doesn't; the old one does.
	check(me._lantern.global_position.is_equal_approx(lantern0 + Vector3(0, 1, 0)) and me._flashlight.global_position.is_equal_approx(beam0),
		"lift: the lantern 1 up, the new flashlight where it was: %s %s" % [me._lantern.global_position, me._flashlight.global_position])
	var mode_before: String = AvatarScript.flashlight_mode
	AvatarScript.flashlight_mode = "old"
	draw.call()
	var old_beam := me._flashlight.global_position
	AvatarScript.flashlight_mode = mode_before
	check(is_equal_approx(old_beam.y, AvatarScript.FLASHLIGHT_HEIGHT + 1.0), "lift: the old flashlight (--flashlight=old) 1 up: %s" % [old_beam])

	# Eye and view's centre: still without `camera` (the default), up with it.
	var eye_still: Vector3 = eye.call()
	var focus_still: Vector3 = rig._focus_goal()
	check(eye_still.is_equal_approx(eye0) and focus_still.is_equal_approx(focus0) and me.camera_lift() == Vector3.ZERO,
		"lift: set_lift(1) without camera: the first-person eye and the angled view's centre stay: %s %s" % [eye_still, focus_still])
	api.character.set_lift(1.0, Vector3.ZERO, true)
	draw.call()
	var eye1: Vector3 = eye.call()
	check(eye1.is_equal_approx(eye0 + Vector3(0, 1, 0)) and is_equal_approx(eye0.y, CameraRig.EYE_HEIGHT),
		"lift: first person's eye at 1.55 + 1: %s" % [eye1])
	var focus1: Vector3 = rig._focus_goal()
	check(focus1.is_equal_approx(focus0 + Vector3(0, 1, 0)) and is_equal_approx(focus0.y, CameraRig.BODY_MID),
		"lift: the angled view's centre at 0.85 + 1: %s" % [focus1])
	me.set_first_person(true)
	var muzzle1 := me.muzzle_position()
	me.set_first_person(false)
	var bar1: Vector3 = combat._bar_position(5)
	check(bar1.is_equal_approx(bar0 + Vector3(0, 1, 0)) and muzzle1.is_equal_approx(muzzle0 + Vector3(0, 1, 0)),
		"lift: the health bar and the fallback muzzle (body hidden) 1 up: %s %s" % [bar1, muzzle1])

	# Across: half a tile east with the body facing west. Everything that follows moves east in the world.
	me.rotation.y = PI / 2.0
	api.character.set_lift(1.0, Vector3(0.5, 0, 0), true)
	draw.call()
	var east := Vector3(0.5, 1, 0)
	var lantern_off := me._lantern.global_position - me.global_position
	var beam_off := me._flashlight.global_position - me.global_position
	var root_world: Vector3 = me.global_transform.basis * (me._pose.root_offset - root0) if has_rig else east
	check(lantern_off.is_equal_approx(Vector3(0.5, AvatarScript.LANTERN_HEIGHT + 1.0, 0)) and beam_off.is_equal_approx(Vector3(0.5, AvatarScript.BEAM_HEIGHT, 0))
		and root_world.is_equal_approx(east) and rig._focus_goal().is_equal_approx(focus0 + east),
		"lift: an offset (0.5, 0, 0) facing west: lantern, new flashlight (across only), body and view's centre half a tile east: %s %s %s" % [lantern_off, beam_off, root_world])
	me.rotation.y = 0.0

	# Caps.
	api.character.set_lift(100.0)
	var caps := [api.character.state()["lift"]]
	api.character.set_lift(1.0, Vector3(5, 0, 0))
	caps.append(api.character.state()["lift"])
	api.character.set_lift(-3.0)
	caps.append(api.character.state()["lift"])
	api.character.set_lift(NAN, Vector3(NAN, 0, INF))
	caps.append(api.character.state()["lift"])
	api.character.set_lift(1.0, Vector3(0, 7, 0))
	caps.append(api.character.lift())
	check(caps[0] == Vector3(0, 16, 0) and (caps[1] as Vector3).is_equal_approx(Vector3(1, 1, 0)) and caps[2] == Vector3.ZERO
		and caps[3] == Vector3(0, 0, 1) and caps[4] == Vector3(0, 1, 0) and me.lifted() == Vector3(0, 1, 0),
		"lift: capped at 16 up and 1 across; a negative or NAN height 0, an infinite offset 1; the offset's y ignored: %s" % [caps])

	# Two add-ons add up; each reads its own; the watch isn't started by set_lift alone.
	api.character.set_lift(0.2)
	other.character.set_lift(0.8)
	await get_tree().process_frame
	check(is_equal_approx(me.drawn_lift(), 1.0) and api.character.lift() == Vector3(0, 0.2, 0) and other.character.lift() == Vector3(0, 0.8, 0)
		and not host.watch._char_apis.has(other) and other.character._respawned.get_connections().is_empty(),
		"lift: 0.2 and 0.8 from two add-ons draw 1.0, each reads its own; set_lift alone left the watch off for that add-on")
	host.stop(disk)
	check(is_equal_approx(me.drawn_lift(), 0.2) and api.character.lift() == Vector3(0, 0.2, 0), "lift: one stopped, the other's stays: %.2f" % [me.drawn_lift()])

	# Stop puts everything back.
	api.character.clear_lift()
	draw.call()
	check(me.drawn_lift() == 0.0 and api.character.state()["lift"] == Vector3.ZERO and me._lantern.global_position.is_equal_approx(lantern0),
		"lift: clear_lift: nothing lifted")
	host.start(disk)
	other = disk["object"]
	other.character.set_lift(2.0, Vector3(0, 0, 0.5), true)
	draw.call()
	var up_lantern := me._lantern.global_position
	var up_eye: Vector3 = eye.call()
	host.stop(disk)
	draw.call()
	check(up_eye.is_equal_approx(eye0 + Vector3(0, 2, 0.5)) and host.lift_sum(true) == Vector3.ZERO and me.camera_lift() == Vector3.ZERO,
		"lift: an add-on's camera lift moved the eye 2 up; stopping it takes its camera part away: %s" % [up_eye])
	check(up_lantern.is_equal_approx(lantern0 + Vector3(0, 2, 0.5)) and me._lantern.global_position.is_equal_approx(lantern0)
		and me._flashlight.global_position.is_equal_approx(beam0) and eye.call().is_equal_approx(eye0) and rig._focus_goal().is_equal_approx(focus0)
		and combat._bar_position(5).is_equal_approx(bar0) and api.character.state() == state0 and (not has_rig or me._pose.root_offset.is_equal_approx(root0)),
		"lift: an add-on stopped: body, lights, eye, centre, bar and state() back as they were")
	host.start(disk)
	other = disk["object"]

	# Suspended in a vehicle and dead, kept for after.
	api.character.set_lift(1.0)
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 2, "hp": 250, "mhp": 250, "v": 7})
	draw.call()
	var in_car := [me.drawn_lift(), me._lantern.global_position, me.lifted()]
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 3, "hp": 0, "mhp": 250, "v": 0})
	draw.call()
	var dead := [me.drawn_lift(), me._lantern.global_position, me.lifted()]
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 4, "hp": 250, "mhp": 250, "v": 0})
	draw.call()
	check(in_car[0] == 0.0 and (in_car[1] as Vector3).is_equal_approx(lantern0) and in_car[2] == Vector3.ZERO and dead[0] == 0.0 and dead[2] == Vector3.ZERO
		and (dead[1] as Vector3).is_equal_approx(lantern0) and is_equal_approx(me.drawn_lift(), 1.0) and api.character.lift() == Vector3(0, 1, 0),
		"lift: not drawn in a vehicle or dead; drawn again on foot: %s %s" % [in_car, dead])

	# Reach and aim: from the game's place; a raised eye picks less far across the ground, never further.
	var input := PlayerInput.new()
	input.avatar = me
	var spots := [Vector2(19, 5), Vector2(21, 5), Vector2(10, 16.5)]
	var reach0 := spots.map(func(p: Vector2) -> Array: return [input._in_reach(p, Vector2i.ONE), input._bridge_reach(p)])
	api.character.set_lift(8.0)
	draw.call()
	var reach8 := spots.map(func(p: Vector2) -> Array: return [input._in_reach(p, Vector2i.ONE), input._bridge_reach(p)])
	check(reach0 == reach8 and reach0[0] == [true, true] and reach0[1][0] == false, "lift: reach answers the same lifted 8: %s" % [reach8])
	var aim_world := WorldMirror.new()
	aim_world.pick_build_usec = 1 << 40
	aim_world.protos.add_entities([[1, "lift-test-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "lift-test-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "lift-test-splitter", "splitter", -0.9, -0.5, 0.9, 0.5, 200, 180, 0, 2, 1],
		[4, "lift-test-pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	aim_world.chunks[Vector2i.ZERO] = ChunkView.new()
	input.world = aim_world
	input.rig = rig
	input.fp_pick_models = true
	me.snap_to(Vector2(-40.5, 16.5))
	rig.toggle_first_person()
	var picks := {}
	for d: float in [50.0, 64.0]:
		aim_world._add([700, 1, int((-40.5 + d) * 256), int(16.5 * 256), 0])
		for h: float in [0.0, 8.0]:
			api.character.set_lift(h, Vector3.ZERO, true)
			draw.call()
			var from: Vector3 = rig.camera.global_position
			var to := Vector3(-40.5 + d, 0.4, 16.5)
			rig._look_yaw = -90.0
			rig._look_pitch = rad_to_deg(atan2(from.y - to.y, to.x - from.x))
			rig._process(0.0)
			input._aim_from(rig.aim_position(), null)
			picks["%d@%d" % [d, h]] = not input._aim.is_empty()
		aim_world._remove(700)
	rig.toggle_first_person()
	check(picks == {"50@0": true, "50@8": true, "64@0": true, "64@8": false},
		"lift: the crosshair picks a chest 50 tiles off lifted or not, one 64 off only from the ground's eye (AIM_RANGE from the eye): %s" % [picks])
	check((Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\"")).is_empty(), "lift: nothing sent to the game: %s" % [Bridge.capture])

	# api.world.stand_height_at: the walk-on types' tops, 0 elsewhere.
	fake.world = aim_world
	aim_world._add([801, 2, 5 * 256 + 128, 5 * 256 + 128, 0])  # a belt
	aim_world._add([802, 3, 8 * 256 + 128, 6 * 256, 4])  # a splitter turned east: x 8 to 9, z 5 to 7
	aim_world._add([803, 1, 12 * 256 + 128, 5 * 256 + 128, 0])  # a chest
	aim_world._add([804, 4, 14 * 256 + 128, 5 * 256 + 128, 0])  # a pipe
	var belt_top := AimPick.height_of(aim_world, aim_world.entities[801])
	var split_top := AimPick.height_of(aim_world, aim_world.entities[802])
	var heights := [api.world.stand_height_at(Vector2(2.5, 2.5)), api.world.stand_height_at(Vector2(5.5, 5.5)), api.world.stand_height_at(Vector2(8.7, 5.3)),
		api.world.stand_height_at(Vector2(8.3, 6.7)), api.world.stand_height_at(Vector2(12.5, 5.5)), api.world.stand_height_at(Vector2(14.5, 5.5))]
	check(heights[0] == 0.0 and belt_top > 0.0 and is_equal_approx(heights[1], belt_top) and is_equal_approx(heights[2], split_top) and is_equal_approx(heights[3], split_top)
		and heights[4] == 0.0 and heights[5] == 0.0 and is_equal_approx(belt_top, Visuals.height_for(aim_world.protos.entity(2))),
		"stand_height_at: 0 on bare ground, a belt's top (the placeholder's before a model), a splitter's across its turned box, 0 on a chest and a pipe: %s" % [heights])
	fake.world = world_before
	check(api.world.stand_height_at(Vector2(5.5, 5.5)) == 0.0, "stand_height_at: 0 without the world's index")

	# Hills: the lights and eye over the hill, at the offset's place.
	var img := Image.create(4, 4, false, Image.FORMAT_RF)
	img.fill(Color(3, 0, 0))
	api.terrain.set_heights(img, Vector2(-8, -8), 4.0)
	me.snap_to(Vector2(0, 0))
	api.character.set_lift(1.0, Vector3.ZERO, true)
	draw.call()
	var hill := [me._lantern.global_position.y, eye.call().y]
	for y in 4:
		for x in 4:
			img.set_pixel(x, y, Color(float(x), 0, 0))
	api.terrain.set_heights(img, Vector2(-8, -8), 4.0)
	api.character.set_lift(1.0, Vector3(1, 0, 0), true)
	draw.call()
	var slope := [me._lantern.global_position, GroundHeight.at(1, 0), GroundHeight.at(0, 0)]
	api.terrain.clear()
	check(is_equal_approx(hill[0], AvatarScript.LANTERN_HEIGHT + 3.0 + 1.0) and is_equal_approx(hill[1], 3.0 + CameraRig.EYE_HEIGHT + 1.0)
		and is_equal_approx((slope[0] as Vector3).y, AvatarScript.LANTERN_HEIGHT + float(slope[1]) + 1.0) and float(slope[1]) != float(slope[2]),
		"lift: on a 3-tile hill the lantern at 2.5 + 3 + 1, the eye at 3 + 1.55 + 1; on a slope, the hill at the offset's place: %s %s" % [hill, slope])

	# The game's end drops every lift; the next game's avatar starts on the ground.
	api.character.set_lift(1.0)
	other.character.set_lift(1.0)
	host.game_ended()
	var after_end := [me.lifted(), api.character.lift(), other.character.lift()]
	host.game_started()
	await get_tree().process_frame
	check(after_end == [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO] and me.lifted() == Vector3.ZERO and host.lift_sum() == Vector3.ZERO,
		"lift: game over drops every lift, a new game starts on the ground: %s" % [after_end])

	# Back as the rest of the test had it.
	Bridge.capture = capture_before
	fake.avatar = plain
	rig.target = target_before
	# None was in the tree: their own parts made in their declarations (PlayerInput's tools) go too.
	var loose: Array = [combat._back, combat._fill]
	for cv in aim_world.chunks.values():
		if cv is Node:
			loose.append(cv)
	var keep := [me, rig, input, aim_world]
	var owners: Array = [input, aim_world]
	var i := 0
	while i < owners.size():  # their parts' own parts too
		for prop: Dictionary in (owners[i] as Node).get_property_list():
			var v = (owners[i] as Node).get(prop["name"])
			if v is Node and (v as Node).get_parent() == null and not loose.has(v) and not keep.has(v):
				loose.append(v)
				owners.append(v)
		i += 1
	loose.append_array([combat, input, aim_world])
	for n: Node in loose:
		n.free()
	me.queue_free()
	await get_tree().process_frame


## (1.7, step 6 pieces 3 and 4) api.character's attachments at the promised bones and points, the `view`
## anchor, frame() and rig(), the muzzle and tools, and the pose layer with its joint ranges: drawn only
## (nothing sent, `position` unmoved), nothing made or run before an add-on uses them.


func _character_attach(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const CharacterPoints := preload("res://scripts/player/character_points.gd")
	var disk: Dictionary = host.find("disk-addon")
	var plain = fake.avatar
	var target_before = rig.target
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)
	fake.avatar = me
	rig.target = me
	host._push_character()
	me.snap_to(Vector2(10, 5))
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	var draw := func() -> void:
		me._process(0.0)
		rig._process(0.0)
	draw.call()
	var has_rig: bool = me._rig != null
	check(has_rig, "attach: the character's rig loads")
	if not has_rig:
		fake.avatar = plain
		rig.target = target_before
		me.queue_free()
		return
	var pos0 := me.position

	# Nothing before use.
	check(me._attached.is_empty() and me._holder == null and me._anim.layer.is_empty() and me._addon_muzzle.is_empty()
		and not me.tools_hidden and rig._view_anchor == null and host._attached.is_empty() and host._poses.is_empty(),
		"attach: nothing made before an add-on uses it (no holder, no layer, no view anchor)")

	# Attach on right_hand: the forearm's tail, the gun's frame.
	var gun := Node3D.new()
	var part := MeshInstance3D.new()
	part.mesh = BoxMesh.new()
	gun.add_child(part)
	var stray := Node3D.new()
	check(not api.character.attach(stray, "left_ear") and not api.character.attach(null, "head"), "attach: an unknown name or no node gives false")
	stray.free()
	check(api.character.attach(gun, "right_hand"), "attach: right_hand takes a node")
	draw.call()
	var tail: Vector3 = me._pose.tail_of("forearm_r")
	var want: Transform3D = me.global_transform * me._pose.frame("forearm_r", Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), tail))
	check(gun.global_transform.is_equal_approx(want) and (api.character.frame("right_hand") as Transform3D).is_equal_approx(want),
		"attach: right_hand at the forearm's tail in the gun's frame, frame() the same: %s %s" % [gun.global_position, want.origin])
	check(gun.get_parent() == me._holder and part.layers == AvatarScript.SELF_LAYER, "attach: on the avatar's holder, on SELF_LAYER (the lantern's shadows don't see it)")
	var at0 := gun.global_position
	api.character.set_lift(1.0)
	draw.call()
	check(gun.global_position.is_equal_approx(at0 + Vector3(0, 1, 0)), "attach: rides a lift of 1: %s" % [gun.global_position - at0])
	api.character.clear_lift()
	var img := Image.create(4, 4, false, Image.FORMAT_RF)
	img.fill(Color(3, 0, 0))
	api.terrain.set_heights(img, Vector2(-8, -8), 4.0)
	me.snap_to(Vector2(0, 0))
	draw.call()
	var on_hill := gun.global_position.y
	api.terrain.clear()
	draw.call()
	check(is_equal_approx(on_hill, gun.global_position.y + 3.0), "attach: on a 3-tile hill 3 up, as the body's shader draws it: %.3f %.3f" % [on_hill, gun.global_position.y])
	me.snap_to(Vector2(10, 5))
	draw.call()
	me.vehicle = 7
	me._update_body()
	var in_car := gun.is_visible_in_tree()
	me.vehicle = 0
	me._update_body()
	me.set_first_person(true)
	var in_fp := gun.is_visible_in_tree()
	me.set_first_person(false)
	check(not in_car and not in_fp and gun.is_visible_in_tree(), "attach: hidden in a vehicle and in first person, shown again after")
	me.set_armor("mech-armor")
	draw.call()
	var mech_tail: Vector3 = me.global_transform * me._pose.point("forearm_r", me._pose.tail_of("forearm_r"))
	var mech_info: Dictionary = api.character.rig()
	var mech_top: Transform3D = api.character.frame("head_top")
	check(gun.get_parent() == me._holder and gun.global_position.is_equal_approx(mech_tail) and bool(mech_info["mech"])
		and absf(mech_top.origin.y - me.global_position.y - 2.76) < 0.06,
		"attach: through a change to mech armour, at the mech's forearm's tail; rig().mech; head_top %.2f up" % [mech_top.origin.y - me.global_position.y])
	me.set_armor("")
	draw.call()

	# frame() and rig().
	var info: Dictionary = api.character.rig()
	var top: Transform3D = api.character.frame("head_top")
	var answered := 0
	for n in CharacterPoints.names():
		if api.character.frame(n) is Transform3D:
			answered += 1
	check(not bool(info["mech"]) and (info["bones"] as Array).size() == 11 and (info["points"] as Array).size() == 12
		and absf(float(info["height"]) - 1.72) < 0.05 and absf(top.origin.y - me.global_position.y - 1.72) < 0.06
		and answered == 23 and api.character.frame("nose") == null,
		"frame/rig: 11 bones, 12 points, all 23 answer, head_top %.2f up (1.72), height %.2f; an unknown name null" % [top.origin.y - me.global_position.y, float(info["height"])])

	# The points sit outside the body: a backpack behind the back, glasses in front of the eyes.
	var outside := _points_outside()
	check(outside.is_empty(), "points: back, chest and eyes outside the body's surface in every look: %s" % [outside])

	# view: on the camera, shown only in first person.
	var vm := Node3D.new()
	check(api.character.attach(vm, "view", Transform3D(Basis.IDENTITY, Vector3(0.2, -0.2, -0.4))), "view: attach takes a node")
	draw.call()
	var angled_shown := vm.is_visible_in_tree()
	rig.toggle_first_person()
	draw.call()
	var fp_shown := vm.is_visible_in_tree()
	var fp_at := vm.global_position
	var cam_at: Vector3 = rig.camera.global_transform * Vector3(0.2, -0.2, -0.4)
	var view_frame = api.character.frame("view")
	var cam_frame: Transform3D = rig.camera.global_transform
	rig.toggle_first_person()
	draw.call()
	check(vm.get_parent() == rig._view_anchor and rig._view_anchor.get_parent() == rig.camera and not angled_shown and fp_shown
		and fp_at.is_equal_approx(cam_at) and view_frame is Transform3D and (view_frame as Transform3D).is_equal_approx(cam_frame),
		"view: a child of the camera's anchor, shown only in first person, at the offset from the eye: %s %s %s" % [angled_shown, fp_shown, fp_at])

	# Across games: kept out of the freed nodes and put on the next game's avatar.
	host.game_ended()
	var kept := is_instance_valid(gun) and gun.get_parent() == null and is_instance_valid(vm) and vm.get_parent() == null
	host.game_started()
	await get_tree().process_frame
	check(kept and gun.get_parent() == me._holder and vm.get_parent() == rig._view_anchor, "attach: kept through the game's end, put on the next game's avatar")

	# detach hands it back, unfreed; stopping an add-on frees its nodes.
	api.character.detach(vm)
	check(is_instance_valid(vm) and vm.get_parent() == null, "detach: out of the tree, not freed")
	vm.free()
	var theirs := Node3D.new()
	var other = disk["object"]
	check(other.character.attach(theirs, "back"), "attach: a second add-on's backpack")
	host.stop(disk)
	await get_tree().process_frame
	check(not is_instance_valid(theirs) and is_instance_valid(gun), "attach: stopping an add-on frees its nodes, not another's")
	host.start(disk)
	other = disk["object"]

	# Muzzle and tools.
	me._anim._w["aim"] = 1.0
	me.firing = true
	draw.call()
	var muzzle0 := me.muzzle_position()
	var gun_shown: bool = me._gun.visible
	api.character.hide_tools(true)
	draw.call()
	var gun_hidden := not me._gun.visible
	api.character.hide_tools(false)
	draw.call()
	check(gun_shown and gun_hidden and me._gun.visible, "tools: hide_tools(true) hides Zenith's gun while aiming, false shows it")
	api.character.set_muzzle(gun, Vector3(0, 0, -0.5))
	var addon_muzzle := me.muzzle_position()
	api.character.clear_muzzle()
	check(addon_muzzle.is_equal_approx(gun.global_transform * Vector3(0, 0, -0.5)) and me.muzzle_position().is_equal_approx(muzzle0),
		"muzzle: set_muzzle moves muzzle_position() to the node's point, clear_muzzle() puts Zenith's back")
	me._anim._w["aim"] = 0.0
	me.firing = false
	draw.call()

	# The pose layer.
	var idx: Dictionary = me._pose.index
	var head: int = idx["head"]
	var skins0: Array = me._pose.skins.duplicate()
	var turns0: PackedVector3Array = me._pose.turns.duplicate()
	api.character.set_pose({"head": Vector3(0.3, 0, 0), "tail": Vector3(1, 0, 0), "spine": "not a turn"})
	draw.call()
	var others_same := true
	for i in me._pose.names.size():
		if i != head and not (me._pose.skins[i] as Transform3D).is_equal_approx(skins0[i]):
			others_same = false
	check(me._pose.turns[head].is_equal_approx(turns0[head] + Vector3(0.3, 0, 0)) and others_same
		and not (me._pose.skins[head] as Transform3D).is_equal_approx(skins0[head]) and api.character.pose().keys() == ["head"],
		"pose: 0.3 added to head turns the head's skin by it and no other bone's; unknown keys ignored")
	api.character.clear_pose()
	draw.call()
	check(me._pose.turns == turns0 and me._anim.layer.is_empty(), "pose: clear_pose() gives Zenith's own pose back")
	me._anim._w["run"] = 1.0
	me._anim._run_phase = 1.0
	draw.call()
	var ua: int = idx["upper_arm_r"]
	var running_turn: Vector3 = me._pose.turns[ua]
	api.character.set_pose({"right_upper_arm": Vector3(1.2, 0, 0)}, {"replace": ["right_upper_arm"]})
	draw.call()
	var replaced: Vector3 = me._pose.turns[ua]
	api.character.set_pose({"right_upper_arm": Vector3(1.2, 0, 0)}, {"replace": true, "weight": 0.5})
	draw.call()
	var half: Vector3 = me._pose.turns[ua]
	check(running_turn != Vector3.ZERO and replaced.is_equal_approx(Vector3(1.2, 0, 0)) and half.is_equal_approx(running_turn.lerp(Vector3(1.2, 0, 0), 0.5)),
		"pose: replace at weight 1 gives the add-on's turn while running, 0.5 half way: %s %s %s" % [running_turn, replaced, half])
	me._anim._w["run"] = 0.0
	api.character.set_pose({"right_lower_arm": Vector3(10, NAN, -10)})
	draw.call()
	var fa: Vector3 = me._pose.turns[idx["forearm_r"]]
	var r: Array = me._anim.JOINTS["forearm_r"]
	check(fa.is_equal_approx(Vector3((r[1] as Vector3).x, turns0[idx["forearm_r"]].y, (r[0] as Vector3).z)),
		"pose: a turn of (10, nan, -10) on right_lower_arm held to the joint's range, not-a-number as 0: %s" % [fa])
	me.health = 0
	me._anim._fall = 1.0
	draw.call()
	var dead_with: PackedVector3Array = me._pose.turns.duplicate()
	api.character.clear_pose()
	draw.call()
	var dead_without: PackedVector3Array = me._pose.turns.duplicate()
	me._anim._fall = 0.0
	me.health = 250
	draw.call()
	check(dead_with == dead_without, "pose: dead (the fall at its end), the layer has no effect")
	# Two add-ons, in start order: the later started one's replace is laid over the earlier's.
	var api_first: bool = int(host.find(api.id).get("start_n", 0)) < int(disk.get("start_n", 0))
	var first_api = api if api_first else other
	var second_api = other if api_first else api
	first_api.character.set_pose({"head": Vector3(0.2, 0, 0)}, {"replace": true})
	second_api.character.set_pose({"head": Vector3(0.4, 0, 0)}, {"replace": true})
	draw.call()
	var both: Vector3 = me._pose.turns[head]
	second_api.character.set_pose({"head": Vector3(0.1, 0, 0)})
	draw.call()
	var added: Vector3 = me._pose.turns[head]
	check(both.is_equal_approx(Vector3(0.4, 0, 0)) and added.is_equal_approx(Vector3(0.3, 0, 0)),
		"pose: two add-ons in start order: the later's replace wins, an added turn adds to the earlier's: %s %s" % [both, added])
	host.stop(disk)
	draw.call()
	var after_stop: Vector3 = me._pose.turns[head]
	check(after_stop.is_equal_approx(Vector3(0.2, 0, 0) if api_first else turns0[head]), "pose: a stopped add-on's layer goes, the other's stays: %s" % [after_stop])
	host.start(disk)
	api.character.clear_pose()
	draw.call()
	check(me._pose.turns == turns0, "pose: everything cleared, Zenith's own pose")

	# Zenith's own animations inside the joint table (both looks, every --anim-pose state, the widest aim twist).
	var outside_joints := _zenith_in_joints()
	check(outside_joints.is_empty(), "pose: Zenith's own animations stay inside the joint table: %s" % [outside_joints])

	# Bounds: drawn only.
	api.character.detach(gun)
	gun.free()
	check(me.position == pos0, "attach/pose: avatar.position unchanged to the bit")
	check((Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\"")).is_empty(), "attach/pose: nothing sent to the game: %s" % [Bridge.capture])
	Bridge.capture = capture_before
	fake.avatar = plain
	rig.target = target_before
	host._push_character()
	me.queue_free()
	await get_tree().process_frame


## Every pose of Zenith's own (each --anim-pose state, plain and mech, and the widest aim twist), stepped
## 3 s, against character_anim.gd JOINTS; the bones and axes outside it.


func _zenith_in_joints() -> Array:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	var out: Array = []
	for armor in ["", "mech-armor"]:
		for st in ["", "walk", "run", "exo", "back", "stop", "mine", "aim", "ready", "runaim", "runready", "hover", "fly", "flyloop", "twist"]:
			var a := AvatarScript.new()
			add_child(a)
			a.set_process(false)
			a.set_armor(armor)
			a._demo = "runaim" if st == "twist" else st
			for f in 180:
				if st == "twist":
					a._anim.aim_twist = 1.25 * (1.0 if f % 120 < 60 else -1.0)
				a._animate(1.0 / 60.0)
				if a._anim._fall > 0.0:
					continue
				for i in a._pose.names.size():
					var n: String = a._pose.names[i]
					var r: Array = a._anim.JOINTS[n]
					var t: Vector3 = a._pose.turns[i]
					if t != t.clamp(r[0], r[1]) and out.size() < 8:
						out.append("%s %s %s %s" % [armor, st, n, t])
			a.free()
	return out


## The named points that sit inside a look's surface (back behind, chest and eyes in front of every
## vertex near the centre line at that height), at rest.


func _points_outside() -> Array:
	const ModelLibrary := preload("res://scripts/world/model_library.gd")
	const CharacterPose := preload("res://scripts/player/character_pose.gd")
	const CharacterPoints := preload("res://scripts/player/character_points.gd")
	var bad: Array = []
	for look in ["character", "character-armor-2", "character-armor-3", "character-mech-armor"]:
		var mesh = ModelLibrary.mesh_for(look)
		var pose := CharacterPose.new()
		if not (mesh is ArrayMesh and pose.load_rig(look)):
			bad.append(look + ": no model")
			continue
		var verts := PackedVector3Array()
		for s in (mesh as ArrayMesh).get_surface_count():
			verts.append_array(ModelLibrary.ModelLods.arrays_of(mesh, s)[Mesh.ARRAY_VERTEX])
		for name in ["back", "chest", "eyes"]:
			var p: Vector3 = (CharacterPoints.rest(pose, look, name)[1] as Transform3D).origin
			var front := INF
			var behind := -INF
			for v in verts:
				if absf(v.x - p.x) < 0.1 and absf(v.y - p.y) < 0.05:
					front = minf(front, v.z)
					behind = maxf(behind, v.z)
			if (name == "back" and p.z < behind) or (name != "back" and p.z > front):
				bad.append("%s %s at z %.3f, the surface %.3f" % [look, name, p.z, behind if name == "back" else front])
	return bad


## The owner's belt step-up (core, drawn only: "doesn't move camera or actual player position"): on a
## belt the body eases up onto its top and down again off it; the game's place, the first-person eye and
## the angled view's centre stay; state()'s height and lift include it; an add-on's lift adds to it;
## Settings > Graphics > Step onto belts off and --belt-step=off give no rise; api.world.stand_height_at
## is the core's answer; the stand height is looked up only when the drawn place moves.


func _belt_step(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const StandHeight := preload("res://scripts/world/stand_height.gd")
	const AimPick := preload("res://scripts/world/aim_pick.gd")
	var plain = fake.avatar
	var world_before = fake.world
	var target_before = rig.target
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)  # stepped by hand: _process(dt) is one frame
	fake.avatar = me
	rig.target = me
	host._push_lift()
	var w := WorldMirror.new()
	w.pick_build_usec = 1 << 40
	w.protos.add_entities([[1, "step-test-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "step-test-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "step-test-pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[4, "step-test-heat-pipe", "heat-pipe", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	w._add([901, 1, 5 * 256 + 128, 5 * 256 + 128, 0])  # a belt on (5.5, 5.5)
	w._add([902, 2, 8 * 256 + 128, 5 * 256 + 128, 0])  # a chest on (8.5, 5.5)
	w._add([903, 3, 11 * 256 + 128, 5 * 256 + 128, 0])  # a pipe-to-ground on (11.5, 5.5)
	w._add([904, 4, 14 * 256 + 128, 5 * 256 + 128, 0])  # a heat pipe on (14.5, 5.5)
	me.world = w
	fake.world = w
	var top := AimPick.height_of(w, w.entities[901])
	me.update_from({"t": "me", "u": 5, "x": 640, "y": 1408, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	me.snap_to(Vector2(2.5, 5.5))
	const DT := 1.0 / 60.0
	var frames := func(n: int) -> void:
		for i in n:
			me._process(DT)
			rig._process(DT)
	var eye := func() -> Vector3:
		if not rig.first_person:
			rig.toggle_first_person()
		rig._process(0.0)
		var at: Vector3 = rig.camera.global_position
		rig.toggle_first_person()
		return at
	var has_rig: bool = me._rig != null
	frames.call(2)
	var lantern0 := me._lantern.position
	var eye_ground: Vector3 = eye.call()
	var focus_ground: Vector3 = rig._focus_goal()
	check(AvatarScript.belt_step() and me.stand_lift() == 0.0 and top > 0.0, "belt step: on by default, nothing under bare ground; the belt's top %.3f" % top)
	check(api.world.stand_height_at(Vector2(5.5, 5.5)) == StandHeight.at(w, Vector2(5.5, 5.5)) and is_equal_approx(StandHeight.at(w, Vector2(5.5, 5.5)), top)
		and StandHeight.at(w, Vector2(8.5, 5.5)) == 0.0 and top <= AvatarScript.STAND_MAX,
		"belt step: api.world.stand_height_at gives the belt's top, 0 on a chest; a belt's under the core's cap %.2f" % AvatarScript.STAND_MAX)
	var pipe_top := AimPick.height_of(w, w.entities[903])
	check(pipe_top > 0.0 and is_equal_approx(api.world.stand_height_at(Vector2(11.5, 5.5)), pipe_top) and api.world.stand_height_at(Vector2(14.5, 5.5)) > 0.0
		and StandHeight.at(w, Vector2(11.5, 5.5), StandHeight.BELTS) == 0.0 and StandHeight.at(w, Vector2(14.5, 5.5), StandHeight.BELTS) == 0.0,
		"belt step: stand_height_at keeps the whole answer for add-ons (a pipe-to-ground's top %.3f, a heat pipe's); the belt family alone has neither" % pipe_top)
	var box0: AABB = me._rig.custom_aabb if has_rig else AABB()

	# Onto the belt: eased up, not popped.
	me.snap_to(Vector2(5.5, 5.5))
	frames.call(1)
	var first := me.stand_lift()
	var up_share := first / top
	frames.call(5)
	var at_tenth := me.stand_lift()
	frames.call(30)
	var pos_on := me.position
	var eye_on: Vector3 = eye.call()
	var focus_on: Vector3 = rig._focus_goal()
	var st: Dictionary = api.character.state()
	check(first > 0.0 and first < top * 0.6 and at_tenth > top * 0.9 and is_equal_approx(me.stand_lift(), top),
		"belt step: eased onto the belt's top, part way after a frame, most of the way in 0.1 s: %.3f %.3f %.3f of %.3f" % [first, at_tenth, me.stand_lift(), top])
	check(is_equal_approx(me.drawn_lift(), top) and is_equal_approx(me.lifted().y, top) and (not has_rig or me._anim.extra_offset.is_equal_approx(Vector3(0, top, 0)))
		and is_equal_approx(me._lantern.position.y - lantern0.y, top),
		"belt step: the body (the pose's root offset) and the lantern drawn on the belt: %s" % [me._anim.extra_offset])
	check(pos_on == Vector3(5.5, 0, 5.5) and me.ground_position() == Vector2(5.5, 5.5) and me.camera_lift() == Vector3.ZERO,
		"belt step: the game's place untouched: %s" % [pos_on])
	check(is_equal_approx(eye_on.y, eye_ground.y) and is_equal_approx(focus_on.y, focus_ground.y) and is_equal_approx(eye_on.y, CameraRig.EYE_HEIGHT)
		and is_equal_approx(focus_on.y, CameraRig.BODY_MID),
		"belt step: the first-person eye and the angled view's centre don't rise: %s %s" % [eye_on, focus_on])
	check(is_equal_approx(float(st["height"]), top) and (st["lift"] as Vector3).is_equal_approx(Vector3(0, top, 0)),
		"belt step: state()'s height and lift include it: %s %s" % [st["height"], st["lift"]])

	# An add-on's lift adds to it; without camera the eye still stays.
	api.character.set_lift(1.0)
	frames.call(1)
	check(is_equal_approx(me.drawn_lift(), top + 1.0) and is_equal_approx(eye.call().y, eye_ground.y) and is_equal_approx(rig._focus_goal().y, focus_ground.y)
		and (api.character.state()["lift"] as Vector3).is_equal_approx(Vector3(0, top + 1.0, 0)),
		"belt step: an add-on's lift adds to it; neither moves the camera: %.3f" % me.drawn_lift())
	api.character.set_lift(1.0, Vector3.ZERO, true)
	frames.call(1)
	check(is_equal_approx(eye.call().y, eye_ground.y + 1.0) and is_equal_approx(rig._focus_goal().y, focus_ground.y + 1.0),
		"belt step: an add-on's camera lift moves the eye and centre by its own 1, not the belt's step: %s" % [eye.call()])
	api.character.clear_lift()

	# Cost: standing still, no look-ups; a move, one.
	var looks0: int = me.stand_lookups
	frames.call(20)
	var still_looks: int = me.stand_lookups - looks0
	me.snap_to(Vector2(5.6, 5.5))
	frames.call(20)
	check(still_looks == 0 and me.stand_lookups - looks0 == 1, "belt step: no look-up in 20 frames standing still, one for a move: %d, %d" % [still_looks, me.stand_lookups - looks0])

	# Off it: eased down, a touch slower than up.
	me.snap_to(Vector2(2.5, 5.5))
	frames.call(1)
	var down_share := 1.0 - me.stand_lift() / top
	frames.call(30)
	check(down_share > 0.0 and down_share < up_share and me.stand_lift() == 0.0 and me.drawn_lift() == 0.0,
		"belt step: off the belt it eases back to 0, a touch slower than up (%.2f of the way after a frame, up %.2f)" % [down_share, up_share])
	me.snap_to(Vector2(8.5, 5.5))
	frames.call(30)
	check(me.stand_lift() == 0.0, "belt step: a chest isn't stood on")
	me.snap_to(Vector2(11.5, 5.5))
	frames.call(30)
	var on_pipe := me.stand_lift()
	me.snap_to(Vector2(14.5, 5.5))
	frames.call(30)
	check(on_pipe == 0.0 and me.stand_lift() == 0.0, "belt step: pipes-to-ground and heat pipes are walked past at ground level by the core: %.3f %.3f" % [on_pipe, me.stand_lift()])

	# A tall walk-on model: the core's step-up stops at STAND_MAX.
	w.protos.add_entities([[5, "step-test-tall-loader", "loader", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	w._add([905, 5, 17 * 256 + 128, 5 * 256 + 128, 0])
	var tall_top := AimPick.height_of(w, w.entities[905])
	me.snap_to(Vector2(17.5, 5.5))
	frames.call(30)
	check(is_equal_approx(me.stand_lift(), minf(tall_top, AvatarScript.STAND_MAX)) and me.stand_lift() <= AvatarScript.STAND_MAX,
		"belt step: a loader stood on, no higher than STAND_MAX: %.3f (its top %.3f)" % [me.stand_lift(), tall_top])

	# The culling box: the old size on the ground, grown while a lift or the step-up is set, back after.
	if has_rig:
		var on_step: AABB = me._rig.custom_aabb
		api.character.set_lift(3.0, Vector3(1.0, 0, 0))
		var lifted_box: AABB = me._rig.custom_aabb
		api.character.clear_lift()
		me.snap_to(Vector2(2.5, 5.5))
		frames.call(60)
		var back: AABB = me._rig.custom_aabb
		check(box0 == AABB(Vector3(-2, -1, -2), Vector3(4, 8, 4)) and back == box0 and is_equal_approx(on_step.size.y, 8.0 + AvatarScript.STAND_MAX) and on_step.size.x == 4.0
			and is_equal_approx(lifted_box.size.y, 8.0 + 3.0 + AvatarScript.STAND_MAX) and is_equal_approx(lifted_box.size.x, 6.0) and is_equal_approx(lifted_box.position.x, -3.0),
			"belt step: the culling box is the old 4 x 8 x 4 on the ground, grown only while stepped up or lifted, back after: %s %s %s %s" % [box0, on_step, lifted_box, back])

	# Turned off: the setting, and --belt-step=off.
	Settings.set_value("graphics", "belt_step", false, false)
	me.snap_to(Vector2(5.5, 5.5))
	frames.call(30)
	var with_setting_off := me.stand_lift()
	Settings.reset_value("graphics", "belt_step")
	frames.call(30)
	var setting_back := me.stand_lift()
	AvatarScript.belt_step_switch = false
	me.snap_to(Vector2(2.5, 5.5))
	frames.call(2)
	me.snap_to(Vector2(5.5, 5.5))
	frames.call(30)
	var with_switch_off := me.stand_lift()
	AvatarScript.belt_step_switch = true
	check(with_setting_off == 0.0 and is_equal_approx(setting_back, top) and with_switch_off == 0.0 and not ("--belt-step=off" in OS.get_cmdline_user_args()),
		"belt step: Step onto belts off gives no rise, on again it steps up, --belt-step=off none: %.3f %.3f %.3f" % [with_setting_off, setting_back, with_switch_off])

	# Back as the rest of the test had it.
	fake.avatar = plain
	fake.world = world_before
	rig.target = target_before
	host._push_lift()
	me.world = null
	# Not in the tree: the world's chunks and its own parts made in its declarations go too.
	var loose: Array = []
	for cv in w.chunks.values():
		if cv is Node:
			loose.append(cv)
	var owners: Array = [w]
	var i := 0
	while i < owners.size():
		for prop: Dictionary in (owners[i] as Node).get_property_list():
			var v = (owners[i] as Node).get(prop["name"])
			if v is Node and (v as Node).get_parent() == null and not loose.has(v) and v != me and v != rig and not owners.has(v):
				loose.append(v)
				owners.append(v)
		i += 1
	loose.append(w)
	for n: Node in loose:
		if is_instance_valid(n):
			n.free()
	me.queue_free()
	await get_tree().process_frame


## Step 6, pieces 1 and 2 (API 1.7): api.camera.set_modifier, drawn on the player's three views only,
## summed and capped by the host, gone on stop and at the game's end, kept out of take-over's saved FOV;
## take({"input": false, "aim": "center"}) and the one aims_center(). The bound pinned: walking reads the
## view from before the modifier, nothing is sent, the character and its reach don't move.


func _camera_modifiers(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const PlayerInput := preload("res://scripts/player/player_input.gd")
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	var plain = fake.avatar
	var target_before = rig.target
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)
	fake.avatar = me
	rig.target = me
	me.snap_to(Vector2(10, 5))
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	if rig.first_person:
		rig.toggle_first_person()
	var draw := func() -> void:
		me._process(0.0)
		rig._process(0.0)
	var cam := func() -> Transform3D: return rig.camera.global_transform

	# Nothing before use: no modifier on, the camera as the view puts it.
	draw.call()
	var t0: Transform3D = cam.call()
	var view0: Transform3D = api.camera.player_view()
	var fwd0: Vector3 = rig.ground_forward()
	var right0: Vector3 = rig.ground_right()
	check(not rig._mod_on and not rig._mod_shown and is_equal_approx(rig.camera.fov, 35.0) and api.camera.modifier() == {"offset": Vector3.ZERO, "turn": Vector3.ZERO, "fov": 0.0},
		"modifier: none before use, the FOV the view's own 35")

	# An offset in the camera's frame; the player's view and walking unmoved.
	api.camera.set_modifier(Vector3(0.1, 0, 0))
	draw.call()
	var t1: Transform3D = cam.call()
	check(t1.origin.is_equal_approx(t0.origin + t0.basis.x.normalized() * 0.1) and t1.basis.is_equal_approx(t0.basis) and api.camera.transform() == t1,
		"modifier: an offset of 0.1 moves the angled camera 0.1 along its right: %s" % [t1.origin - t0.origin])
	check(api.camera.player_view().is_equal_approx(view0) and api.camera.modifier()["offset"] == Vector3(0.1, 0, 0), "modifier: player_view() unchanged; modifier() gives it back")
	# A yaw: the picture turns, walking doesn't.
	api.camera.set_modifier(Vector3.ZERO, Vector3(0, 0.2, 0))
	draw.call()
	var turned: Transform3D = cam.call()
	check(absf((-turned.basis.z).angle_to(-t0.basis.z) - 0.2) < 0.001 and turned.origin.is_equal_approx(t0.origin), "modifier: a yaw of 0.2 turns the picture by 0.2 about the eye")
	check(rig.ground_forward() == fwd0 and rig.ground_right() == right0,
		"modifier: ground_forward() and ground_right() (the walk's directions) unchanged to the bit with a yaw on: %s %s" % [rig.ground_forward(), fwd0])
	# The FOV: the angled view's 35 and first person's 75, plus the change; back when cleared.
	api.camera.set_modifier(Vector3.ZERO, Vector3.ZERO, 10.0)
	draw.call()
	var fov_angled: float = rig.camera.fov
	rig.toggle_first_person()
	draw.call()
	var fov_fp: float = rig.camera.fov
	var eye_mod := func(o: Vector3) -> Vector3:
		api.camera.set_modifier(o)
		draw.call()
		return rig.camera.global_position
	var eye0: Vector3 = eye_mod.call(Vector3.ZERO)
	var fov_fp_clear: float = rig.camera.fov
	var eye_up: Vector3 = eye_mod.call(Vector3(0, 1, 0))
	var up_dir: Vector3 = rig.global_transform.basis * rig._base.basis.y
	api.camera.clear_modifier()
	rig.toggle_first_person()
	draw.call()
	check(is_equal_approx(fov_angled, 45.0) and is_equal_approx(fov_fp, 85.0) and is_equal_approx(fov_fp_clear, 75.0) and is_equal_approx(rig.camera.fov, 35.0),
		"modifier: FOV +10 gives 45 angled and 85 in first person; cleared, 75 and 35 again: %s %s %s %s" % [fov_angled, fov_fp, fov_fp_clear, rig.camera.fov])
	check(eye_up.is_equal_approx(eye0 + up_dir) and is_equal_approx(up_dir.length(), 1.0),
		"modifier: an offset of (0, 1, 0) moves first person's eye 1 tile along the camera's up: %s" % [eye_up - eye0])
	check(cam.call().is_equal_approx(t0) and not rig._mod_shown, "modifier: cleared, the camera exactly as before")
	# Orthographic views keep their FOV (it doesn't draw); the offset still applies.
	rig.orthographic = true
	api.camera.set_modifier(Vector3(0.1, 0, 0), Vector3.ZERO, 10.0)
	draw.call()
	var ortho_fov: float = rig.camera.fov
	api.camera.clear_modifier()
	rig.orthographic = false
	draw.call()
	check(is_equal_approx(ortho_fov, 35.0), "modifier: an orthographic view ignores fov: %s" % ortho_fov)

	# Modes: not in the remote view, a ride's film, VR or another add-on's take-over; applied again after.
	var mode_still := func(enter: Callable, leave: Callable) -> bool:
		enter.call()
		draw.call()
		var bare: Transform3D = cam.call()
		var bare_fov: float = rig.camera.fov
		api.camera.set_modifier(Vector3(0.5, 0, 0), Vector3(0.1, 0.1, 0.1), 20.0)
		draw.call()
		var same: bool = cam.call().is_equal_approx(bare) and is_equal_approx(rig.camera.fov, bare_fov)
		leave.call()
		draw.call()
		var modded: Transform3D = cam.call()
		var shown: bool = rig._mod_shown
		api.camera.clear_modifier()
		draw.call()
		return same and shown and not modded.is_equal_approx(cam.call())
	var vr_off := func() -> void:
		rig.vr_view.free()
		rig.vr_view = null
	var stills := [
		mode_still.call(func() -> void: rig.in_remote = true, func() -> void: rig.in_remote = false),
		mode_still.call(func() -> void: rig.cinematic(50.0, 30.0), func() -> void: rig.cinematic_end()),
		mode_still.call(func() -> void: rig.vr_view = Node3D.new(), vr_off),
		mode_still.call(func() -> void: other.camera.take({"input": false}), func() -> void: other.camera.release()),
	]
	check(stills == [true, true, true, true], "modifier: the camera unmoved in remote, ride, vr and an add-on's take-over, applied again after: %s" % [stills])
	draw.call()
	t0 = cam.call()  # the transitions move the view a little at delta 0 (a ride's glide): the reference again

	# Caps and sums.
	api.camera.set_modifier(Vector3(0.1, 0, 0))
	other.camera.set_modifier(Vector3(0, 0.2, 0))
	var two: Array = host.camera_modifier_sum()
	api.camera.set_modifier(Vector3(5, 0, 0), Vector3(2, -2, 2), 100.0)
	var capped: Array = host.camera_modifier_sum()
	api.camera.set_modifier(Vector3(-5, 0, 0), Vector3(-2, 2, -2), -100.0)
	other.camera.clear_modifier()
	var capped_neg: Array = host.camera_modifier_sum()
	draw.call()
	var low_fov: float = rig.camera.fov
	api.camera.set_modifier(Vector3(NAN, 0.3, INF), Vector3(NAN, 0, 0), NAN)
	var nan_kept: Dictionary = api.camera.modifier()
	api.camera.set_modifier(Vector3(NAN, 0, 0), Vector3.ZERO, NAN)
	var nan_only: Dictionary = api.camera.modifier()
	check((two[0] as Vector3).is_equal_approx(Vector3(0.1, 0.2, 0)), "modifier: two add-ons' offsets add: %s" % [two[0]])
	check(is_equal_approx((capped[0] as Vector3).length(), 1.5) and (capped[1] as Vector3).is_equal_approx(Vector3(deg_to_rad(20), deg_to_rad(-20), deg_to_rad(45)))
		and is_equal_approx(float(capped[2]), 30.0) and is_equal_approx(float(capped_neg[2]), -30.0) and (capped_neg[1] as Vector3).is_equal_approx(Vector3(deg_to_rad(-20), deg_to_rad(20), deg_to_rad(-45))),
		"modifier: capped after the sum: an offset of 5 is 1.5 long, pitch and yaw 20 degrees, roll 45, the FOV 30 either way: %s %s" % [capped, capped_neg])
	check(is_equal_approx(low_fov, 10.0), "modifier: the FOV never below 10 (35 less 30): %s" % low_fov)
	check(nan_kept["offset"] == Vector3(0, 0.3, 0) and nan_kept["turn"] == Vector3.ZERO and nan_kept["fov"] == 0.0 and nan_only["offset"] == Vector3.ZERO,
		"modifier: not-a-number (and infinity) count as 0: %s" % [nan_kept])
	api.camera.set_modifier(Vector3(0.2, 0, 0))
	other.camera.set_modifier(Vector3(0, 0.3, 0))
	host.stop(disk)
	var after_stop: Array = host.camera_modifier_sum()
	host.start(disk)
	other = disk["object"]
	check((after_stop[0] as Vector3).is_equal_approx(Vector3(0.2, 0, 0)) and other.camera.modifier()["offset"] == Vector3.ZERO,
		"modifier: stopping one add-on takes its modifier away and leaves the other's: %s" % [after_stop[0]])

	# The switch: --camera-modifiers=off.
	CameraRig.modifiers_on = false
	host._push_camera_mod()
	draw.call()
	var off_still: bool = cam.call().is_equal_approx(t0)
	CameraRig.modifiers_on = true
	host._push_camera_mod()
	draw.call()
	check(off_still and not cam.call().is_equal_approx(t0), "modifier: --camera-modifiers=off: the camera as without one")
	api.camera.clear_modifier()
	draw.call()

	# The player's scale (Settings > Camera > Add-ons' camera motion): before the caps, at once; modifier()
	# gives what the add-on set; an add-on's aim at the centre isn't touched.
	api.camera.set_modifier(Vector3(1, 0, 0))
	Settings.set_value("camera", "addon_motion", 50, false)
	draw.call()
	var half: Transform3D = cam.call()
	var half_set: Dictionary = api.camera.modifier()
	api.camera.set_modifier(Vector3(3, 0, 0))
	var half_capped: Array = host.camera_modifier_sum()
	api.camera.set_modifier(Vector3(1, 0, 0), Vector3(0, 0.2, 0), 10.0)
	Settings.set_value("camera", "addon_motion", 0, false)
	draw.call()
	var none := [cam.call().is_equal_approx(t0), rig._mod_on, rig._mod_shown, is_equal_approx(rig.camera.fov, 35.0), host.camera_modifier_sum()[0] == Vector3.ZERO]
	var none_set: Dictionary = api.camera.modifier()
	api.camera.take({"input": false, "aim": "center"})
	var none_aim: bool = rig.aims_center()
	api.camera.release()
	Settings.set_value("camera", "addon_motion", 100, false)
	draw.call()
	var whole: Transform3D = cam.call()
	api.camera.clear_modifier()
	draw.call()
	check(half.origin.is_equal_approx(t0.origin + t0.basis.x.normalized() * 0.5) and half_set["offset"] == Vector3(1, 0, 0),
		"motion: at 50%% an offset of 1 draws 0.5; modifier() still gives 1: %s %s" % [half.origin - t0.origin, half_set])
	check(is_equal_approx((half_capped[0] as Vector3).length(), 1.5), "motion: scaled before the caps: 3 at 50%% is 1.5: %s" % [half_capped[0]])
	check(none == [true, false, false, true, true] and none_set["fov"] == 10.0 and none_aim,
		"motion: at 0%% nothing is drawn, modifier() keeps the add-on's, aim at the centre still works: %s %s %s" % [none, none_set, none_aim])
	check(not whole.is_equal_approx(t0) and cam.call().is_equal_approx(t0), "motion: back at 100% the modifier is drawn again")

	# Take-over: the player's FOV is saved without the modifier and given back with it.
	rig.toggle_first_person()
	api.camera.set_modifier(Vector3.ZERO, Vector3.ZERO, 10.0)
	draw.call()
	var before_take: float = rig.camera.fov
	api.camera.take({"input": false})
	var saved_fov: float = float(rig._taken.get("fov", -1.0))
	api.camera.release()
	var after_release: float = rig.camera.fov
	api.camera.clear_modifier()
	draw.call()
	check(is_equal_approx(before_take, 85.0) and is_equal_approx(saved_fov, 75.0) and is_equal_approx(after_release, 85.0) and is_equal_approx(rig.camera.fov, 75.0),
		"modifier: take() saves FOV 75, not 85; release() gives 75 plus the 10: %s %s %s" % [before_take, saved_fov, after_release])
	rig.toggle_first_person()
	draw.call()

	# Aim at the centre.
	var middle: Vector2 = rig.get_viewport().get_visible_rect().size * 0.5
	var dot := func() -> bool: return rig._crosshair != null and rig._crosshair.visible
	api.camera.take({"input": false, "aim": "center"})
	var centre := [rig.aims_center(), rig.aim_position() == middle, dot.call()]
	api.camera.release()
	var released := [rig.aims_center(), dot.call()]
	check(centre == [true, true, true] and released == [false, false], "aim: take({input: false, aim: center}): aims_center, the middle, the dot; release() puts both back: %s %s" % [centre, released])
	api.camera.take({"input": false})
	var plain_take: bool = rig.aims_center()
	api.camera.release()
	api.camera.take({"aim": "center"})
	var with_input: bool = rig.aims_center()
	api.camera.release()
	api.camera.take({"input": false, "aim": "center", "crosshair": false})
	var no_dot := [rig.aims_center(), dot.call()]
	api.camera.release()
	check(not plain_take and not with_input and no_dot == [true, false],
		"aim: without aim from the angled view no; with input (the default) no; crosshair false: no dot: %s %s %s" % [plain_take, with_input, no_dot])
	rig.toggle_first_person()
	api.camera.take({"input": false})
	var fp_take := [rig.aims_center(), dot.call()]
	api.camera.release()
	var fp_back := [rig.aims_center(), dot.call()]
	rig.toggle_first_person()
	check(fp_take == [true, false] and fp_back == [true, true], "aim: from first person a take aims at the centre (as before); released, first person's dot again: %s %s" % [fp_take, fp_back])

	# The bound: the character, its reach and what is sent don't follow a 1.5-tile modifier.
	var input := PlayerInput.new()
	input.avatar = me
	var spots := [Vector2(19, 5), Vector2(21, 5), Vector2(10, 16.5)]
	var pos0 := me.position
	var reach0 := spots.map(func(p: Vector2) -> Array: return [input._in_reach(p, Vector2i.ONE), input._bridge_reach(p)])
	api.camera.set_modifier(Vector3(1.5, 0, 0), Vector3(0.3, 0.3, 0.7), 30.0)
	for fp: bool in [false, true]:
		if rig.first_person != fp:
			rig.toggle_first_person()
		draw.call()
	var reach_mod := spots.map(func(p: Vector2) -> Array: return [input._in_reach(p, Vector2i.ONE), input._bridge_reach(p)])
	rig.toggle_first_person()
	api.camera.clear_modifier()
	draw.call()
	check(reach_mod == reach0 and me.position == pos0 and is_equal_approx(rig.modifier_reach(), 0.0),
		"modifier: the character's place and reach unchanged with a 1.5-tile modifier: %s" % [reach_mod])
	# The one message: the stop that take() with "input" (the default) sends as it turns the controls off.
	var sent: Array = (Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\""))
	check(sent.size() == 1 and str(sent[0]).contains("\"walk\""), "modifier and aim: nothing sent to the game but the one take with input's stop: %s" % [sent])

	# The game's end drops every modifier.
	api.camera.set_modifier(Vector3(0.2, 0, 0))
	host.game_ended()
	var ended := [api.camera.modifier()["offset"], rig._mod_on]
	host.game_started()
	await get_tree().process_frame
	check(ended == [Vector3.ZERO, false], "modifier: the game's end drops it: %s" % [ended])

	Bridge.capture = capture_before
	fake.avatar = plain
	rig.target = target_before
	var loose: Array = []
	var owners: Array = [input]
	var i := 0
	while i < owners.size():
		for prop: Dictionary in (owners[i] as Node).get_property_list():
			if str(prop["name"]).begins_with("global_"):
				continue  # read off the tree it only complains
			var v = (owners[i] as Node).get(prop["name"])
			if v is Node and (v as Node).get_parent() == null and not loose.has(v) and v != me and v != rig:
				loose.append(v)
				owners.append(v)
		i += 1
	loose.append(input)
	for n: Node in loose:
		n.free()
	me.queue_free()
	await get_tree().process_frame


## The testing pass over step 6 (mods-cam-test): the cases the coders' checks don't reach. Walking
## diagonally under the biggest sway two add-ons can give, in every view; sums that overflow; the reach
## cut by the capped, scaled offset; the strength on a turn; each of the 22 avatar names; two add-ons'
## muzzles; the view anchor under other modes; attachments through death; a pose's weight 0.


func _cam_group_extra(api, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const CharacterPoints := preload("res://scripts/player/character_points.gd")
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	var plain = fake.avatar
	var target_before = rig.target
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)
	fake.avatar = me
	rig.target = me
	host._push_character()
	me.snap_to(Vector2(10, 5))
	me.update_from({"t": "me", "u": 5, "x": 2560, "y": 1280, "k": 1, "hp": 250, "mhp": 250, "v": 0})
	if rig.first_person:
		rig.toggle_first_person()
	var draw := func() -> void:
		me._process(0.0)
		rig._process(0.0)
	draw.call()
	var pos0 := me.position

	# Walking diagonally under the largest sway (both add-ons past every cap, the FOV kicked both ways),
	# in the angled view turned off the axes, Factorio's view and first person looking off level: the
	# walk's directions, and the 1000-step turn the bridge gets, the same to the bit.
	var walk_turn := func(input: Vector2) -> int:
		var d: Vector3 = rig.ground_right() * input.x + rig.ground_forward() * input.y
		return posmod(int(round(atan2(d.x, -d.z) / TAU * 1000.0)), 1000)
	var inputs := [Vector2(0.7071, 0.7071), Vector2(-0.6, 0.8), Vector2(0.8, -0.6), Vector2(-0.7071, -0.7071)]
	var walk_of := func() -> Array:
		var out: Array = [rig.ground_forward(), rig.ground_right()]
		for i: Vector2 in inputs:
			out.append(walk_turn.call(i))
		return out
	rig.rotate_free(37.0)
	var walk_bad: Array = []
	for view in ["angled", "factorio", "first_person"]:
		if view == "factorio":
			rig.toggle_factorio_view()
		elif view == "first_person":
			if rig.in_factorio_view():
				rig.toggle_factorio_view()
			rig.toggle_first_person()
			rig.look(Vector2(150, -90))
		draw.call()
		draw.call()
		var bare: Array = walk_of.call()
		for fov in [30.0, -30.0]:
			api.camera.set_modifier(Vector3(1.0, -1.0, 1.0), Vector3(0.3, -0.3, 0.7), fov)
			other.camera.set_modifier(Vector3(1.0, 1.0, -1.0), Vector3(0.3, -0.3, 0.7), fov)
			draw.call()
			var swayed: Array = walk_of.call()
			if swayed != bare or not rig._mod_shown:
				walk_bad.append("%s fov %s: %s vs %s" % [view, fov, swayed, bare])
		api.camera.clear_modifier()
		other.camera.clear_modifier()
		draw.call()
	if rig.first_person:
		rig.toggle_first_person()
	rig.rotate_free(-37.0)
	draw.call()
	check(walk_bad.is_empty(), "extra: a diagonal walk under the capped sway and FOV kick of two add-ons, in all three views: the same turn to the bit: %s" % [walk_bad])

	# Sums past a float's range: two finite offsets of 3e38 add to infinity; the camera must stay a number.
	api.camera.set_modifier(Vector3(3e38, 0, 0), Vector3(3e38, 0, 0), 1e300)
	other.camera.set_modifier(Vector3(3e38, 0, 0), Vector3(3e38, 0, 0), 1e300)
	var huge: Array = host.camera_modifier_sum()
	draw.call()
	var huge_cam: Transform3D = rig.camera.global_transform
	var huge_ok: bool = huge_cam.origin.is_finite() and huge_cam.basis.is_finite() and is_finite(rig.camera.fov)
	api.camera.clear_modifier()
	other.camera.clear_modifier()
	draw.call()
	check(huge_ok and (huge[0] as Vector3).is_finite(), "extra: two add-ons' offsets of 3e38 sum past a float: the camera stays finite: sum %s, camera %s" % [huge, huge_cam.origin])
	# The same for turns and FOV: each capped before the sum, so two of 3e38 never add to infinity (times
	# 0% that was not-a-number), at the strength's ends.
	var turn_bad: Array = []
	for strength in [0, 100]:
		Settings.set_value("camera", "addon_motion", strength, false)
		api.camera.set_modifier(Vector3.ZERO, Vector3(3e38, 3e38, 3e38), 3e38)
		other.camera.set_modifier(Vector3.ZERO, Vector3(3e38, 3e38, 3e38), 3e38)
		var big: Array = host.camera_modifier_sum()
		draw.call()
		var big_cam: Transform3D = rig.camera.global_transform
		if not ((big[1] as Vector3).is_finite() and is_finite(float(big[2])) and big_cam.basis.is_finite()
				and big_cam.origin.is_finite() and is_finite(rig.camera.fov)):
			turn_bad.append("%d%%: sum %s, basis %s, fov %s" % [strength, big, big_cam.basis, rig.camera.fov])
	Settings.set_value("camera", "addon_motion", 100, false)
	api.camera.clear_modifier()
	other.camera.clear_modifier()
	draw.call()
	check(turn_bad.is_empty(), "extra: two add-ons' turns and FOV of 3e38 at 0%% and 100%%: a finite basis and FOV: %s" % [turn_bad])

	# The first-person reach: cut by the offset as drawn (summed, capped, scaled), 0 in the remote view.
	rig.toggle_first_person()
	api.camera.set_modifier(Vector3(1.0, 0, 0))
	other.camera.set_modifier(Vector3(1.0, 0, 0))
	draw.call()
	var reach_capped: float = rig.modifier_reach()
	Settings.set_value("camera", "addon_motion", 50, false)
	draw.call()
	var reach_half: float = rig.modifier_reach()
	Settings.set_value("camera", "addon_motion", 100, false)
	rig.in_remote = true
	draw.call()
	var reach_remote: float = rig.modifier_reach()
	rig.in_remote = false
	api.camera.clear_modifier()
	other.camera.clear_modifier()
	draw.call()
	rig.toggle_first_person()
	draw.call()
	check(is_equal_approx(reach_capped, 1.5) and is_equal_approx(reach_half, 1.0) and reach_remote == 0.0,
		"extra: the pick's reach cut by the drawn offset: 2 summed capped to 1.5, 50%% of 2 is 1, none in remote: %s %s %s" % [reach_capped, reach_half, reach_remote])

	# The strength on a turn, before the cap: a yaw of 0.6 is 0.3 at 50% (under 20 degrees), capped at 100%.
	Settings.set_value("camera", "addon_motion", 50, false)
	api.camera.set_modifier(Vector3.ZERO, Vector3(0, 0.6, 0), 20.0)
	var half_turn: Array = host.camera_modifier_sum()
	Settings.set_value("camera", "addon_motion", 100, false)
	var full_turn: Array = host.camera_modifier_sum()
	api.camera.clear_modifier()
	draw.call()
	check(is_equal_approx((half_turn[1] as Vector3).y, 0.3) and is_equal_approx(float(half_turn[2]), 10.0)
		and is_equal_approx((full_turn[1] as Vector3).y, deg_to_rad(20.0)) and is_equal_approx(float(full_turn[2]), 20.0),
		"extra: strength scales turn and FOV before the caps: %s %s" % [half_turn, full_turn])

	# Every avatar name (the 11 bones, the 12 points but view): attach() takes it and the node sits at frame().
	var names_bad: Array = []
	var nodes: Array = []
	for n: String in CharacterPoints.names():
		if n == "view":
			continue
		var node := Node3D.new()
		if not api.character.attach(node, n):
			names_bad.append(n + ": refused")
			node.free()
			continue
		nodes.append([node, n])
	draw.call()
	for e: Array in nodes:
		var f = api.character.frame(str(e[1]))
		if not (f is Transform3D and (e[0] as Node3D).global_transform.is_equal_approx(f)):
			names_bad.append("%s at %s, frame %s" % [e[1], (e[0] as Node3D).global_position, f])
	check(nodes.size() == 22 and names_bad.is_empty(), "extra: all 22 avatar names take a node at their frame(): %d %s" % [nodes.size(), names_bad])
	# Through death: the nodes stay on the holder and follow the fall.
	var head_node: Node3D = null
	for e: Array in nodes:
		if e[1] == "head_top":
			head_node = e[0]
	var head_alive := head_node.global_position
	me.health = 0
	me._anim._fall = 1.0
	draw.call()
	var head_dead := head_node.global_position
	var dead_parent := head_node.get_parent() == me._holder
	me._anim._fall = 0.0
	me.health = 250
	draw.call()
	check(dead_parent and head_dead.y < head_alive.y - 0.3 and head_node.global_position.is_equal_approx(head_alive),
		"extra: through death a node at head_top stays on and falls with the body, back up after: %s %s" % [head_alive, head_dead])
	for e: Array in nodes:
		api.character.detach(e[0])
		(e[0] as Node).free()

	# Two add-ons' muzzles: the newest set wins; cleared or stopped, the other's comes back.
	var mine := Node3D.new()
	var theirs := Node3D.new()
	api.character.attach(mine, "right_hand")
	other.character.attach(theirs, "left_hand")
	draw.call()
	api.character.set_muzzle(mine, Vector3(0, 0, -1))
	other.character.set_muzzle(theirs, Vector3(0, 0, -1))
	var m_theirs := me.muzzle_position()
	var m_theirs_want := theirs.global_transform * Vector3(0, 0, -1)
	other.character.clear_muzzle()
	var m_mine := me.muzzle_position()
	other.character.set_muzzle(theirs, Vector3(0, 0, -1))
	host.stop(disk)
	await get_tree().process_frame
	var m_after_stop := me.muzzle_position()
	host.start(disk)
	other = disk["object"]
	api.character.set_muzzle(mine, Vector3(0, 0, -1))
	mine.free()
	var m_freed := me.muzzle_position()
	api.character.clear_muzzle()
	var m_own := me.muzzle_position()
	check(m_theirs.is_equal_approx(m_theirs_want) and m_mine != m_theirs and m_after_stop.is_equal_approx(m_mine)
		and m_freed.is_equal_approx(m_own) and m_freed.is_finite(),
		"extra: two add-ons' muzzles: the newer's, the other's when it clears or stops, Zenith's when the node is freed: %s %s %s %s" % [m_theirs, m_mine, m_after_stop, m_freed])
	# A muzzle node freed without clear_muzzle(), then the game ends and starts again: the freed entry
	# dropped before the avatar is given the last one (a freed node to its typed argument is a script
	# error), Zenith's own muzzle back.
	var gone := Node3D.new()
	api.character.attach(gone, "right_hand")
	api.character.set_muzzle(gone, Vector3(0, 0, -1))
	gone.free()
	host.game_ended()
	host.game_started()
	await get_tree().process_frame
	draw.call()
	var m_restart := me.muzzle_position()
	check(not host._muzzles.has(api.character) and m_restart.is_equal_approx(m_own) and me._addon_muzzle.is_empty(),
		"extra: a freed muzzle node across a game's end and start: dropped, Zenith's muzzle back: %s %s %s" % [host._muzzles.keys(), m_restart, m_own])
	# attach and the muzzle given a freed node: refused, no script error.
	var freed := Node3D.new()
	freed.free()
	# (through the host: the API's own `node: Node3D` arguments refuse a freed instance before it)
	var attach_freed: bool = host.character_attach(api.character, freed, "right_hand", Transform3D.IDENTITY)
	host.character_muzzle(api.character, freed, Vector3.ZERO)
	check(not attach_freed and not host._muzzles.has(api.character), "extra: attach and the muzzle given a freed node: refused")

	# The view anchor: hidden in first person while the remote view, VR or an add-on has the camera.
	var vm := Node3D.new()
	api.character.attach(vm, "view")
	rig.toggle_first_person()
	draw.call()
	var vis := [vm.is_visible_in_tree()]
	rig.in_remote = true
	draw.call()
	vis.append(vm.is_visible_in_tree())
	rig.in_remote = false
	rig.vr_view = Node3D.new()
	draw.call()
	vis.append(vm.is_visible_in_tree())
	rig.vr_view.free()
	rig.vr_view = null
	other.camera.take({"input": false})
	draw.call()
	vis.append(vm.is_visible_in_tree())
	other.camera.release()
	draw.call()
	vis.append(vm.is_visible_in_tree())
	rig.toggle_first_person()
	draw.call()
	api.character.detach(vm)
	vm.free()
	check(vis == [true, false, false, false, true], "extra: view shown in first person only, not under remote, VR or a take-over: %s" % [vis])

	# A pose at weight 0 (replace or add) leaves Zenith's own; two adds at weight 0.5 add halves.
	var head: int = me._pose.index["head"]
	var turns0: PackedVector3Array = me._pose.turns.duplicate()
	api.character.set_pose({"head": Vector3(0.4, 0, 0)}, {"weight": 0.0, "replace": true})
	draw.call()
	var w0: PackedVector3Array = me._pose.turns.duplicate()
	api.character.set_pose({"head": Vector3(0.4, 0, 0)}, {"weight": 0.5})
	other.character.set_pose({"head": Vector3(0.2, 0, 0)}, {"weight": 0.5})
	draw.call()
	var halves: Vector3 = me._pose.turns[head]
	api.character.clear_pose()
	other.character.clear_pose()
	draw.call()
	check(w0 == turns0 and halves.is_equal_approx(turns0[head] + Vector3(0.3, 0, 0)) and me._pose.turns == turns0,
		"extra: weight 0 changes nothing; two adds at 0.5 give half of each: %s" % [halves - turns0[head]])
	# Infinity in a turn (the host turns only not-a-number to 0): held to the joint, never a NaN bone,
	# whether added or replaced and at any weight, 0 included.
	var inf_bad: Array = []
	for opts: Dictionary in [{}, {"replace": true}, {"weight": 0.0}, {"weight": 0.0, "replace": true}, {"weight": 0.5, "replace": true}]:
		api.character.set_pose({"head": Vector3(INF, -INF, 0)}, opts)
		draw.call()
		var t: Vector3 = me._pose.turns[head]
		if not t.is_finite():
			inf_bad.append("%s: %s" % [opts, t])
	api.character.clear_pose()
	draw.call()
	check(inf_bad.is_empty(), "extra: a turn of infinity never makes a NaN bone: %s" % [inf_bad])

	# The bound for all of it.
	host.stop(disk)
	host.start(disk)
	check(me.position == pos0, "extra: avatar.position unchanged to the bit")
	check((Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\"")).is_empty(),
		"extra: nothing sent to the game by modifiers, attachments, muzzles or poses: %s" % [Bridge.capture])
	Bridge.capture = capture_before
	fake.avatar = plain
	rig.target = target_before
	host._push_character()
	me.queue_free()
	await get_tree().process_frame


## Stopping an add-on frees its API object and the parts (addon_api.gd _let_go): each part holds the
## object and it them, so before about 12 objects were left for each start. Counted over 20 stops and
## starts of an add-on that ignores the API, and of one that connects a character signal and lifts.


func _api_leak(host) -> void:
	var disk: Dictionary = host.find("disk-addon")
	var cycle := func(touch: bool) -> void:
		host.stop(disk)
		host.start(disk)
		if touch:
			var a = disk["object"]
			a.character.footfall.connect(func(_f: String, _p: Vector3) -> void: pass)
			a.character.set_lift(0.1)
	for i in 3:
		cycle.call(true)
		await get_tree().process_frame
	var per_start := {}
	for touch: bool in [false, true]:
		for i in 3:
			await get_tree().process_frame
		var before := Performance.get_monitor(Performance.OBJECT_COUNT)
		for i in 20:
			cycle.call(touch)
			await get_tree().process_frame
		for i in 3:
			await get_tree().process_frame
		per_start[touch] = (Performance.get_monitor(Performance.OBJECT_COUNT) - before) / 20.0
	print("leak: objects left per add-on start: %.2f plain, %.2f with api.character used" % [per_start[false], per_start[true]])
	check(float(per_start[false]) < 1.0 and float(per_start[true]) < 1.0,
		"stop frees the add-on's API object and its parts: objects left per start %.2f plain, %.2f with api.character" % [per_start[false], per_start[true]])
	(disk["object"]).character.clear_lift()


## The character group as a player and an add-on meet it (testing, mods-char-test): a walk over a belt, a
## splitter turned east, an underground, a chest and bare ground in the angled view, Factorio's view and
## first person, with the camera still and nothing popping; the step-up's look-ups counted while walking
## and timed; a belt built under a standing character; reach and what is sent while stepped up; the
## camera's modes once each (the remote view over first person, an add-on's take-over), not on the frames
## between; a new game's first armour and guns; stopping one add-on leaving another's handlers and lift;
## footfalls named right and left for several loops each way.


func _char_extra(api, node: Node, host, fake, rig) -> void:
	const AvatarScript := preload("res://scripts/player/avatar.gd")
	const StandHeight := preload("res://scripts/world/stand_height.gd")
	const AimPick := preload("res://scripts/world/aim_pick.gd")
	const PlayerInput := preload("res://scripts/player/player_input.gd")
	const UiModel := preload("res://scripts/ui/factorio/ui_model.gd")
	const AddonCharacter := preload("res://scripts/addons/addon_character.gd")
	var plain = fake.avatar
	var world_before = fake.world
	var target_before = rig.target
	var hud_before = fake.hud
	var capture_before = Bridge.capture
	Bridge.capture = []
	var me := AvatarScript.new()
	add_child(me)
	me.set_process(false)  # stepped by hand: _process(dt) is one frame
	fake.avatar = me
	rig.target = me
	host._push_lift()
	var w := WorldMirror.new()
	w.pick_build_usec = 1 << 40
	w.protos.add_entities([[1, "x-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[2, "x-chest", "container", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1],
		[3, "x-splitter", "splitter", -0.9, -0.5, 0.9, 0.5, 200, 180, 0, 2, 1],
		[4, "x-underground", "underground-belt", -0.5, -0.5, 0.5, 0.5, 200, 180, 0, 1, 1]])
	w.chunks[Vector2i.ZERO] = ChunkView.new()
	for x in [5, 6, 7]:
		w._add([910 + x, 1, x * 256 + 128, 5 * 256 + 128, 4])  # belts x 5 to 8 on the row z 5.5, running east
	w._add([920, 3, 10 * 256 + 128, 6 * 256, 4])  # a splitter turned east: x 10 to 11, z 5 to 7
	w._add([921, 4, 13 * 256 + 128, 5 * 256 + 128, 4])  # an underground's entrance, x 13 to 14
	w._add([922, 2, 16 * 256 + 128, 5 * 256 + 128, 0])  # a chest, x 16 to 17
	me.world = w
	fake.world = w
	var tops := {"belt": AimPick.height_of(w, w.entities[915]), "splitter": AimPick.height_of(w, w.entities[920]),
		"underground": AimPick.height_of(w, w.entities[921])}
	check(float(tops["belt"]) > 0.0 and float(tops["splitter"]) > AvatarScript.STAND_MAX and float(tops["underground"]) > AvatarScript.STAND_MAX,
		"walk: the walk-on tops, the splitter's and underground's over the step-up's cap %.2f: %s" % [AvatarScript.STAND_MAX, tops])
	# The core stands the body at most STAND_MAX up (owner: "stepping onto belts"); add-ons get the whole top.
	for key: String in tops.keys():
		tops[key] = minf(float(tops[key]), AvatarScript.STAND_MAX)
	const DT := 1.0 / 60.0
	var k := [1000]
	var input := PlayerInput.new()
	input.avatar = me

	# One walk east along z 5.5 from x 1.5 to 20.5 at Factorio's running speed (0.15 a tick), a `me` a tick
	# and a frame a tick, as the game sends them; then 90 frames standing at the end.
	var walk := func() -> Dictionary:
		var out := {"frames": 0, "lookups": 0, "moved_frames": 0, "max_jump": 0.0, "cam_y": [], "rig_y": [], "goal_at": {},
			"pos_y_max": 0.0, "ground_off": 0.0, "reach_same": true, "still_frames_looking": 0, "still_lookups_late": 0}
		me.snap_to(Vector2(1.5, 5.5))
		me._stand = 0.0
		for i in 3:
			me._process(DT)
			rig._process(DT)
		var looks0: int = me.stand_lookups
		var last_pos := me.position
		var last_stand := me.stand_lift()
		var x := 1.5
		while x < 20.5:
			x += 0.15
			k[0] += 1
			me.update_from({"t": "me", "u": 5, "x": int(round(x * 256.0)), "y": 5 * 256 + 128, "k": k[0], "d": 4, "w": 1, "hp": 250, "mhp": 250, "v": 0})
			var before: int = me.stand_lookups
			me._process(DT)
			rig._process(DT)
			out["frames"] += 1
			if me.position != last_pos:
				out["moved_frames"] += 1
			last_pos = me.position
			out["max_jump"] = maxf(float(out["max_jump"]), absf(me.stand_lift() - last_stand))
			last_stand = me.stand_lift()
			(out["cam_y"] as Array).append(rig.camera.global_position.y)
			(out["rig_y"] as Array).append(rig.global_position.y)
			out["pos_y_max"] = maxf(float(out["pos_y_max"]), absf(me.position.y))
			out["ground_off"] = maxf(float(out["ground_off"]), me.ground_position().distance_to(Vector2(me.position.x, me.position.z)))
			if me.stand_lookups - before > 1:
				out["lookups_over_one"] = true
			# Where the drawn body stands, what it stands on (the goal, not the eased value).
			for spot: String in ["belt:6.5", "splitter:10.5", "underground:13.5", "chest:16.5", "ground:9.0", "ground:19.5"]:
				var sx := float(spot.get_slice(":", 1))
				if absf(me.position.x - sx) < 0.08 and not out["goal_at"].has(spot):
					out["goal_at"][spot] = me._stand_goal
			# Reach from the game's place: a tile just inside the build distance east of where the game has the
			# character is in reach, one a hair further isn't; the bridge's own reach the same way.
			var edge := Vector2(me.position.x, me.position.z)
			var r_in := edge + Vector2(input.build_reach() + 0.49, 0.0)
			var r_out := edge + Vector2(input.build_reach() + 0.51, 0.0)
			var b_in := edge + Vector2(input.build_reach() + PlayerInput.BRIDGE_REACH_SLACK - 0.01, 0.0)
			var b_out := edge + Vector2(input.build_reach() + PlayerInput.BRIDGE_REACH_SLACK + 0.01, 0.0)
			if not (input._in_reach(r_in, Vector2i.ONE) and not input._in_reach(r_out, Vector2i.ONE) and input._bridge_reach(b_in) and not input._bridge_reach(b_out)):
				out["reach_same"] = false
		out["lookups"] = me.stand_lookups - looks0
		# Standing: the drawn body settles; how many frames still look up, and none once settled.
		var settled := -1
		for i in 90:
			var before2: int = me.stand_lookups
			me._process(DT)
			rig._process(DT)
			if me.stand_lookups > before2:
				out["still_frames_looking"] += 1
				if i >= 60:
					out["still_lookups_late"] += 1
		k[0] += 120  # the game's clock went on while it stood
		return out

	# Angled view.
	check(rig.view_mode() == "angled", "walk: starts in the angled view")
	var angled: Dictionary = walk.call()
	# Factorio's view.
	rig.toggle_factorio_view()
	rig._process(DT)
	var f6_mode: String = rig.view_mode()
	var factorio: Dictionary = walk.call()
	var f6_after: String = rig.view_mode()
	rig.toggle_factorio_view()
	rig._process(DT)
	# First person.
	rig.toggle_first_person()
	var first: Dictionary = walk.call()
	rig.toggle_first_person()
	var spread := func(a: Array) -> float: return (a.max() - a.min()) if not a.is_empty() else -1.0
	var b_top: float = tops["belt"]
	check(f6_mode == "factorio" and f6_after == "factorio", "walk: Factorio's view held through the walk: %s %s" % [f6_mode, f6_after])
	for pair: Array in [["angled", angled], ["Factorio's view", factorio], ["first person", first]]:
		var r: Dictionary = pair[1]
		var ga: Dictionary = r["goal_at"]
		check(is_equal_approx(float(ga.get("belt:6.5", -1)), b_top) and is_equal_approx(float(ga.get("splitter:10.5", -1)), float(tops["splitter"]))
			and is_equal_approx(float(ga.get("underground:13.5", -1)), float(tops["underground"])) and float(ga.get("chest:16.5", -1)) == 0.0
			and float(ga.get("ground:9.0", -1)) == 0.0 and float(ga.get("ground:19.5", -1)) == 0.0,
			"walk (%s): stood on the belt, the splitter turned east and the underground (capped); not on the chest or bare ground: %s" % [pair[0], ga])
		check(float(r["max_jump"]) <= 0.45 * maxf(b_top, maxf(float(tops["splitter"]), float(tops["underground"]))),
			"walk (%s): no pop, the most the step-up moved in one frame %.4f (tops %s)" % [pair[0], r["max_jump"], tops])
		check(float(spread.call(r["cam_y"])) < 0.0005 and float(spread.call(r["rig_y"])) < 0.0005,
			"walk (%s): the camera's height didn't move over belts, splitter, underground and off: camera %.5f, rig %.5f" % [pair[0], spread.call(r["cam_y"]), spread.call(r["rig_y"])])
		check(float(r["pos_y_max"]) == 0.0 and float(r["ground_off"]) == 0.0 and bool(r["reach_same"]),
			"walk (%s): position on the ground, ground_position the game's, reach the same, every frame" % pair[0])
		check(not r.has("lookups_over_one") and int(r["lookups"]) <= int(r["frames"]) and int(r["lookups"]) == int(r["moved_frames"]) and int(r["still_lookups_late"]) == 0,
			"walk (%s): look-ups %d over %d frames (%d moved), at most one a frame; standing after: %d frames still looked up while it settled, none after 60 frames"
				% [pair[0], r["lookups"], r["frames"], r["moved_frames"], r["still_frames_looking"]])
	print("cost: step-up look-ups walking: %d in %d frames; standing after a walk: %d frames of look-ups while the drawn body settles"
		% [angled["lookups"], angled["frames"], angled["still_frames_looking"]])

	# One look-up timed, on this small world and on 400 belts round the point.
	var t0 := Time.get_ticks_usec()
	for i in 10000:
		StandHeight.at(w, Vector2(6.5, 5.5))
	var small_us := float(Time.get_ticks_usec() - t0) / 10000.0
	var id := 3000
	for y in 20:
		for x in 20:
			w._add([id, 1, (40 + x) * 256 + 128, (40 + y) * 256 + 128, 4])
			id += 1
	t0 = Time.get_ticks_usec()
	for i in 10000:
		StandHeight.at(w, Vector2(50.5, 50.5))
	var dense_us := float(Time.get_ticks_usec() - t0) / 10000.0
	t0 = Time.get_ticks_usec()
	for i in 10000:
		StandHeight.at(w, Vector2(30.5, 30.5))
	var bare_us := float(Time.get_ticks_usec() - t0) / 10000.0
	check(dense_us < 50.0, "cost: one step-up look-up %.2f us on a belt, %.2f us among 400 belts, %.2f us on bare ground" % [small_us, dense_us, bare_us])
	for i in 400:
		w._remove(3000 + i)

	# The known limit: a belt built under a character standing still isn't stood on until it moves.
	me.snap_to(Vector2(22.5, 5.5))
	for i in 5:
		me._process(DT)
	w._add([930, 1, 22 * 256 + 128, 5 * 256 + 128, 4])
	for i in 30:
		me._process(DT)
	var under_still := me.stand_lift()
	me.snap_to(Vector2(22.52, 5.5))
	for i in 30:
		me._process(DT)
	check(under_still == 0.0 and is_equal_approx(me.stand_lift(), b_top),
		"step-up's known limit: a belt built under a standing character isn't stood on (%.3f) until it moves (%.3f)" % [under_still, me.stand_lift()])

	# Nothing was sent to the game by the walks, the step-up or the lifts.
	check((Bridge.capture as Array).filter(func(t: String) -> bool: return not t.contains("\"hello\"")).is_empty(), "walk: nothing sent to the game: %s" % [Bridge.capture])

	# Modes: once each, not on the frames between; the remote view over first person; a camera lift never
	# moves the remote view.
	node.modes.clear()
	rig.toggle_first_person()
	for i in 10:
		await get_tree().process_frame
	api.character.set_lift(2.0, Vector3.ZERO, true)
	var anchor := Node3D.new()
	add_child(anchor)
	anchor.position = Vector3(40, 0, 40)
	rig.target = anchor  # factorio_ui.gd remote_view
	rig.in_remote = true
	for i in 10:
		await get_tree().process_frame
	rig._process(DT)
	var remote_eye: Vector3 = rig.camera.global_position
	var remote_mode: String = api.camera.mode()
	rig.target = me
	rig.in_remote = false
	for i in 10:
		await get_tree().process_frame
	rig._process(DT)
	var back_eye: Vector3 = rig.camera.global_position
	api.character.clear_lift()
	rig.toggle_first_person()
	for i in 10:
		await get_tree().process_frame
	check(node.modes == [["first_person", "angled"], ["remote", "first_person"], ["first_person", "remote"], ["angled", "first_person"]],
		"modes: first person, the remote view over it, back, angled: once each over 40 frames: %s" % [node.modes])
	check(remote_mode == "remote" and remote_eye.is_equal_approx(Vector3(40, CameraRig.EYE_HEIGHT, 40)) and back_eye.is_equal_approx(me.position + Vector3(0, CameraRig.EYE_HEIGHT + 2.0, 0)),
		"modes: the remote view with first person on sits at the remote point, the camera lift not added; back on the character it is: %s %s" % [remote_eye, back_eye])
	anchor.queue_free()
	var disk: Dictionary = host.find("disk-addon")
	var other = disk["object"]
	node.modes.clear()
	other.camera.take()
	for i in 5:
		await get_tree().process_frame
	var taken_mode: String = api.camera.mode()
	var taken_player: String = api.camera.player_mode()
	other.camera.release()
	for i in 5:
		await get_tree().process_frame
	check(taken_mode == "addon" and taken_player == "angled" and node.modes == [["addon", "angled"], ["angled", "addon"]],
		"modes: an add-on's take-over and release, once each: %s" % [node.modes])

	# Stopping one add-on removes exactly its handlers and its lift: the fixture's stay, counted.
	var counts := func(a) -> Array:
		var part = a._character
		var n := 0
		if part != null:
			for s in AddonCharacter.SIGNALS:
				n += (part as Object).get_signal_connection_list("_" + s).size()
		return [n, a.camera._mode_changed.get_connections().size()]
	var mine_before: Array = counts.call(api)
	other.character.footfall.connect(func(_f: String, _p: Vector3) -> void: pass)
	other.character.died.connect(func(_p: Vector3) -> void: pass)
	other.camera.mode_changed.connect(func(_m: String, _b: String) -> void: pass)
	api.character.set_lift(0.5, Vector3(0.25, 0, 0), true)
	other.character.set_lift(1.5, Vector3.ZERO, false)
	await get_tree().process_frame
	var both_lift: Vector3 = host.lift_sum()
	var other_part = other._character
	host.stop(disk)
	await get_tree().process_frame
	var mine_after: Array = counts.call(api)
	check(mine_before == mine_after and mine_after[0] > 0 and host.lift_sum() == Vector3(0.25, 0.5, 0) and host.lift_sum(true) == Vector3(0.25, 0.5, 0)
		and both_lift == Vector3(0.25, 2.0, 0) and host.watch._char_apis.has(api) and not host.watch._char_apis.has(other) and not host.watch._mode_apis.has(other)
		and not host._lifts.has(other_part) and other_part._footfall.get_connections().is_empty() and other_part._died.get_connections().is_empty(),
		"stop: the other add-on's handlers, lift and watch entries go; this one's %s handlers and lift stay: %s -> %s" % [mine_after, both_lift, host.lift_sum()])
	api.character.clear_lift()
	host.start(disk)
	# The review's case: an add-on keeps api.character at its start and connects to it only later (after
	# game_started, or when a setting is switched on). Nothing read a signal yet: unwatched.
	var late_api = disk["object"]
	var kept_part = late_api.character
	var late_hits: Array = []

	# A new game: its first armour and guns fire nothing, its later changes do.
	var model := UiModel.new()
	var hud := FakeHud.new()
	var ui := FakeCharUi.new()
	ui.model = model
	hud.ui = ui
	add_child(hud)
	fake.hud = hud
	var heard := Recorder.new()
	heard.hear(api.character, ["armor_changed", "gun_selected", "vehicle_entered", "damaged", "respawned", "died"])
	host.game_ended()
	host.game_started()
	await get_tree().process_frame
	me.update_from({"t": "me", "u": 8, "x": 0, "y": 0, "k": 1, "hp": 120, "mhp": 250, "sd": 5, "msd": 50, "v": 4})
	Bridge.message_received.emit({"t": "me", "u": 8, "x": 0, "y": 0, "k": 1, "hp": 120, "mhp": 250, "sd": 5, "msd": 50, "v": 4})
	model.handle({"t": "slots", "l": {"armor": [["power-armor", 1]]}})
	model.set_guns(2, [["pistol", "firearm-magazine", 1, 5, 10], ["submachine-gun", "", 0, 0, 0]])
	for i in 3:
		await get_tree().process_frame
	var first_values := heard.got.duplicate()
	model.handle({"t": "slots", "l": {"armor": [["heavy-armor", 1]]}})
	model.set_guns(1, [["pistol", "firearm-magazine", 1, 5, 10], ["submachine-gun", "", 0, 0, 0]])
	await get_tree().process_frame
	check(first_values.is_empty() and heard.named("armor_changed") == [["armor_changed", "heavy-armor"]] and heard.named("gun_selected") == [["gun_selected", 1, "pistol"]],
		"a new game: its first `me` (in a vehicle, hurt), armour and guns fire nothing; the next changes once each: %s then %s" % [first_values, heard.got])

	# The kept copy, connected now, after game_started: the watch starts for that add-on and its handler hears.
	var late_unwatched: bool = not host.watch._char_apis.has(late_api)
	kept_part.damaged.connect(func(h: int, sd: int) -> void: late_hits.append([h, sd]))
	check(late_unwatched and host.watch._char_apis.has(late_api),
		"a kept api.character connected after game_started: the watch starts for that add-on (unwatched before: %s)" % late_unwatched)

	# Shields: armour with shields swapped for plain armour (`sd` and `msd` stop coming), or for a smaller
	# shield, is no damage; a hit on the new, smaller shield is.
	heard.got.clear()
	var shield_me := func(k: int, sd: int, msd: int) -> void:
		var msg := {"t": "me", "u": 8, "x": 0, "y": 0, "k": k, "hp": 120, "mhp": 250, "v": 0}
		if msd > 0:
			msg["sd"] = sd
			msg["msd"] = msd
		me.update_from(msg)
		Bridge.message_received.emit(msg)
		await get_tree().process_frame
	await shield_me.call(10, 40, 50)  # shielded armour, full-ish
	await shield_me.call(11, 0, 0)  # swapped for plain armour: no `sd`
	var after_plain := heard.named("damaged").duplicate()
	await shield_me.call(12, 30, 50)  # shielded again (a rise: nothing)
	await shield_me.call(13, 20, 30)  # a smaller shield's armour: a lower maximum, a new baseline
	var after_smaller := heard.named("damaged").duplicate()
	await shield_me.call(14, 10, 30)  # a real hit on it
	await get_tree().process_frame
	check(after_plain.is_empty() and after_smaller.is_empty() and heard.named("damaged") == [["damaged", 0, 10]],
		"shields: taking shielded armour off, or swapping to a smaller shield, fires no damaged; a hit after does (0, 10): %s %s %s"
			% [after_plain, after_smaller, heard.named("damaged")])
	check(late_hits == [[0, 10]], "the kept api.character connected late hears that hit too: %s" % [late_hits])

	# Footfalls over several loops each way: right and left alternating, the right first.
	if me._rig != null:
		var anim = me._anim
		for way: float in [1.0, -1.0]:
			anim._run_phase = TAU * (0.75 if way > 0.0 else 0.25)
			anim.running = true
			var feet: Array = []
			var start: int = anim.footfalls
			var guard := 0
			while anim.footfalls < start + 8 and guard < 20000:
				var n: int = anim.footfalls
				anim.step(me._pose, DT, way * 0.05)
				if anim.footfalls > n:
					feet.append("right" if anim.right_foot else "left")
				guard += 1
			anim.running = false
			check(feet == ["right", "left", "right", "left", "right", "left", "right", "left"],
				"footfall %s over four loops: %s" % ["forwards" if way > 0.0 else "backwards", feet])

	# Back as the rest of the test had it.
	Bridge.capture = capture_before
	fake.avatar = plain
	fake.world = world_before
	fake.hud = hud_before
	rig.target = target_before
	host._push_lift()
	me.world = null
	var loose: Array = []
	for cv in w.chunks.values():
		if cv is Node:
			loose.append(cv)
	var owners: Array = [w, input]
	var i := 0
	while i < owners.size():
		for prop: Dictionary in (owners[i] as Node).get_property_list():
			var v = (owners[i] as Node).get(prop["name"])
			if v is Node and (v as Node).get_parent() == null and not loose.has(v) and v != me and v != rig and not owners.has(v):
				loose.append(v)
				owners.append(v)
		i += 1
	loose.append_array([w, input])
	for n: Node in loose:
		if is_instance_valid(n):
			n.free()
	me.queue_free()
	hud.queue_free()
	await get_tree().process_frame


## An add-on is a program, so one nobody switched is off (bundled ones as bundled.json says, --addons
## ones on); the once-only migration that keeps on what an earlier Zenith had on; --addons-default=on.
