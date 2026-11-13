extends RefCounted
## Pausing the Factorio game from Zenith: the debug menu's Pause (debug_menu.gd); a screenshot's
## pause (addons/shot_pause.gd) takes the same steps.
##
## A tick-paused game runs no mod code: the bridge neither reads nor sends until it resumes (real
## 2.1.24; RCON still runs). So:
## - Zenith pauses only where it can resume: over RCON (a server Zenith's menu started). Single-
##   player (hybrid) and a server started elsewhere have none, and a game paused there would be one
##   Zenith couldn't leave.
## - The pause goes through the bridge's `/f3d-debug pause on`, so the console's rule applies (in
##   multiplayer only admins may); its answer waits until the game resumes, unless it was refused.
## - The connection's timeout is held off meanwhile (Bridge.expect_quiet): the silence is the pause.
## - It resumes over RCON, never through the bridge, which a paused game doesn't run.

const RESUME := "/sc game.tick_paused = false"
const NO_RCON := "Pausing needs RCON, which only a server Zenith's menu started has: a paused game runs no mod code, so Zenith couldn't resume it. Pause in Factorio itself (Ctrl+F9)"
const STAYS_PAUSED := "The game stays paused: press Ctrl+F9 and type /c game.tick_paused = false in Factorio"


## Whether a game Zenith pauses can be resumed: `main` is main.gd, or a stand-in with _has_rcon().
static func can_resume(main) -> bool:
	return main != null and is_instance_valid(main) and main.has_method("_has_rcon") and main._has_rcon()


## Holds the connection's timeout off for `reason` and asks the bridge to pause, through `model`
## (ui_model.gd). Returns the command's id.
static func pause(model, reason: String) -> int:
	Bridge.expect_quiet(reason, true)
	return model.command("/f3d-debug pause on")


## Resumes the game over RCON (await it) and lets the timeout run again. False when RCON was gone.
static func resume(main, reason: String) -> bool:
	var ran := false
	if can_resume(main):
		await main._run_command(RESUME)
		ran = true
	Bridge.expect_quiet(reason, false)
	return ran


## Whether a `cmdr` answer to the pause says it didn't pause (refused, or the game runs): a paused
## game's answer only comes once it resumes, so one that comes while paused means it never paused.
static func refused(msg: Dictionary) -> bool:
	return int(msg.get("na", 0)) == 1 or int(msg.get("ok", 1)) == 0 \
		or (msg.get("dbg") is Dictionary and int(msg["dbg"].get("pa", 0)) == 0)
