extends RefCounted
## api.game (1.7): messages between the add-on and a Factorio mod of its own, the one way an add-on
## changes the game (docs/ADDONS.md, "Messages to your Factorio mod"). The mod, which Factorio gives
## to every player in that game, makes the change; Zenith only carries the messages (`ext`,
## PROTOCOL.md "Messages for add-ons and their mods") and never looks inside them.
##
## A channel is a Factorio mod's name, optionally followed by "/" and a topic ("zenith-sprint",
## "zenith-sprint/state"). The add-on opens the channels it talks on; one add-on holds a channel at a
## time, and only it hears that channel's messages. Messages are best-effort: send the state you want
## ("sprint on") and repeat it while it holds, and let the mod time it out.

## A message from the mod on one of this add-on's channels; `data` as the mod sent it (JSON: a
## Dictionary, Array, String, float or bool).
signal message(channel: String, data: Variant)
## The link came (a game whose bridge carries messages) or went (the game ended or was lost).
signal link_changed(on: bool)
## The mod's handler failed on a message from this add-on on `channel`: its error's text (the bridge
## caught it and logged it naming the mod). After 10 within a minute the bridge closes the channel
## until Zenith connects again, and `text` says "closed after repeated errors".
signal mod_error(channel: String, text: String)

## A message (its whole JSON line) at most this many bytes.
const MAX_BYTES := 4096
## A channel at most this many bytes.
const MAX_CHANNEL := 128
## Each channel sends at most this many messages a second (and this many at once).
const PER_SECOND := 20.0
const MOD_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
## The bridge's own mod: no add-on's channel.
const BRIDGE_MOD := "factorio-3d-bridge"

var _host
var _api
var _open := {}  # channel -> [tokens left, Time.get_ticks_msec() when last counted]


func _init(host, api) -> void:
	_host = host
	_api = api


## A game is on and its bridge carries messages for add-ons.
func available() -> bool:
	return _host.link_on()


## The version of the Factorio mod `name` in this game, "" when the game doesn't have it (or no game
## is on): how an add-on knows its mod is there.
func mod(name: String) -> String:
	return _host.game_mod(name)


## Opens `channel` for this add-on: its messages from the mod come as `message`, and send() may use
## it. False when the name isn't a channel or another add-on has it (the log says which).
func open(channel: String) -> bool:
	if not channel_ok(channel):
		_api.note("api.game.open: \"%s\" isn't a channel (a Factorio mod's name, then optionally / and a topic)" % channel.c_escape())
		return false
	if not _host.claim_channel(channel, _api):
		return false
	if not _open.has(channel):
		_open[channel] = [PER_SECOND, Time.get_ticks_msec()]
	return true


func close(channel: String) -> void:
	if _open.erase(channel):
		_host.release_channel(channel, _api)


## The channels this add-on has open.
func channels() -> PackedStringArray:
	return PackedStringArray(_open.keys())


## Sends `data` (anything JSON can hold but null) to the mod on `channel`. False when it wasn't sent:
## the channel isn't open, no game is on, the bridge carries no messages, the channel's mod isn't in
## this game, the message is over 4 KB, or the channel sent 20 already this second.
func send(channel: String, data: Variant) -> bool:
	if not _open.has(channel) or data == null or not available() or mod(channel.get_slice("/", 0)) == "":
		return false
	var cmd := {"t": "ext", "ch": channel, "d": data}
	if JSON.stringify(cmd).to_utf8_buffer().size() > MAX_BYTES:
		return false
	var bucket: Array = _open[channel]
	var now := Time.get_ticks_msec()
	var tokens := minf(PER_SECOND, float(bucket[0]) + float(now - int(bucket[1])) / 1000.0 * PER_SECOND)
	bucket[1] = now
	if tokens < 1.0:
		bucket[0] = tokens
		return false
	bucket[0] = tokens - 1.0
	Bridge.send(cmd)
	return true


## A channel's form: a mod's name ([A-Za-z0-9_-]), then optionally "/" and a topic without control
## characters; 1-128 bytes; not the bridge's own name.
static func channel_ok(channel: String) -> bool:
	var size := channel.to_utf8_buffer().size()
	if size == 0 or size > MAX_CHANNEL:
		return false
	var mod_name := channel.get_slice("/", 0)
	if mod_name.is_empty() or mod_name == BRIDGE_MOD:
		return false
	for c in mod_name:
		if not MOD_CHARS.contains(c):
			return false
	for i in channel.length():
		var code := channel.unicode_at(i)
		if code < 32 or code == 127:
			return false
	return true


# The host hands a message on (addon_host.gd _on_ext).
func _receive(channel: String, data: Variant) -> void:
	if _open.has(channel):
		message.emit(channel, data)


# The host hands on the mod's error on one of this add-on's channels (addon_host.gd _on_ext).
func _error(channel: String, text: String) -> void:
	if _open.has(channel):
		mod_error.emit(channel, text)


# The add-on stopped: its channels are free again.
func _close_all() -> void:
	for channel in _open.keys():
		_host.release_channel(channel, _api)
	_open.clear()
