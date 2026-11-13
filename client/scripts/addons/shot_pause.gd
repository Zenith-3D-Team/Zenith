extends Node
## A screenshot's pause (api.view.screenshot's `pause`, docs/ADDONS.md): the Factorio game held
## while the picture is taken and let go after it. It holds through the bridge's `/f3d-debug hold`
## (console.lua), so the console's rule applies (in multiplayer only admins may) and a refusal just
## means no pause.
##
## The hold is Factorio's slowest game speed (0.01), not tick_paused: a tick-paused game runs no
## on_tick, so its bridge neither reads nor sends and only RCON could resume it (single-player has
## none). Slowed, the bridge still ticks about once every 1.7 s, reads `hold off` and puts the speed
## back; and the mod lets go by itself 30 game ticks (about 50 s) after the hold, so a client that
## crashed or left never leaves the game slowed. Hence:
## - Works wherever the bridge takes console commands: single-player (hybrid) as well as servers.
## - The bridge's timeout is held off meanwhile (Bridge.expect_quiet): it sends little while slowed.
## - The game is held once the bridge has sent what the shot waits for (the view's chunks): slowed,
##   it would send hardly any.
## - It is let go after the picture, when it is cancelled, when the game ends, and by a watchdog here
##   if the screenshot never finishes. A game the player had paused stays paused (the mod doesn't
##   hold a paused game).
## While held, moving things hold still on their own: every drawn clock follows the game's ticks
## (game_clock.gd), belt items within one update of them.

const QUIET_REASON := "screenshot"
## After asking for the hold, how long the drawn clocks get to come to rest (the bridge takes it on
## its next tick, a frame or two, then ticks once every 1.7 s).
const REST_SECONDS := 0.5
const HOLD := "/f3d-debug hold on"
const LET_GO := "/f3d-debug hold off"

enum { IDLE, READY, HELD, SKIPPED }

## main.gd (or a stand-in): hud.
var main: Node = null
var state := IDLE
var _model = null  # ui_model.gd: command(), command_reply
var _hold_id := -1
var _held_msec := 0
var _token := 0  # which shot a watchdog belongs to


## A screenshot starts: it may hold the game once the bridge is in the game. `model` is ui_model.gd.
func begin(model) -> void:
	_finish_listening()
	state = SKIPPED
	if model == null or not Bridge.world_ready:
		return
	_model = model
	_model.command_reply.connect(_on_reply)
	state = READY


## Each frame of the shot: whether the picture should wait for the hold (the game just held and
## things coming to rest). `bridge_done`: what the bridge sends for it has come, so holding now loses
## nothing.
func holds_shot(bridge_done: bool, watchdog_seconds: float) -> bool:
	match state:
		READY:
			if bridge_done:
				_hold(watchdog_seconds)
			return true
		HELD:
			return Time.get_ticks_msec() - _held_msec < REST_SECONDS * 1000.0
	return false


## The shot is over (taken, failed, cancelled or abandoned): the game is let go if this held it.
func end() -> void:
	var was := state
	state = IDLE
	_token += 1
	if was == HELD:
		_let_go()
	_finish_listening()


func paused() -> bool:
	return state == HELD


func _hold(watchdog_seconds: float) -> void:
	Bridge.expect_quiet(QUIET_REASON, true)
	_hold_id = _model.command(HOLD)
	_held_msec = Time.get_ticks_msec()
	state = HELD
	_token += 1
	var token := _token
	var dog := func() -> void:
		if token == _token and state == HELD:
			print("addons: the screenshot didn't finish in %.0f s: the game is let go" % watchdog_seconds)
			end()
	get_tree().create_timer(watchdog_seconds, true, false, true).timeout.connect(dog)


func _let_go() -> void:
	# The bridge may be held up a moment; the mod lets go by itself in any case (30 game ticks).
	if _model != null and is_instance_valid(_model) and Bridge.connected:
		_model.command(LET_GO)
	Bridge.expect_quiet(QUIET_REASON, false)


func _on_reply(id: int, msg: Dictionary) -> void:
	if id != _hold_id:
		return
	_hold_id = -1
	var refused := int(msg.get("na", 0)) == 1
	var dbg = msg.get("dbg")
	if state == HELD and (refused or int(msg.get("ok", 1)) == 0 or not (dbg is Dictionary) or int(dbg.get("hd", 0)) == 0):
		var why := "refused: console commands are for admins in this game" if refused \
			else ("the game is paused already" if dbg is Dictionary and int(dbg.get("pa", 0)) == 1 else "the bridge can't hold it: an older mod")
		print("addons: the game isn't held for the screenshot (%s)" % why)
		state = SKIPPED
		_token += 1
		Bridge.expect_quiet(QUIET_REASON, false)


func _finish_listening() -> void:
	if _model != null and is_instance_valid(_model) and _model.command_reply.is_connected(_on_reply):
		_model.command_reply.disconnect(_on_reply)
	_model = null
