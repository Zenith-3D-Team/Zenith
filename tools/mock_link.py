"""The mock's side of link.lua: an add-on's messages to its Factorio mod (`ext`, PROTOCOL.md "Messages
for add-ons and their mods"). The mock plays one such mod, the fixture zenith-link-test
(tools/mod_tests/fixtures/zenith-link-test), with the bridge's caps:
  {echo: x}   answered with {echo: x}
  {burst: n}  answered with n messages {i: 1..n} (as many as the cap lets through)
  {who: 1}    answered with {client: the client's port, unit: its character's unit number}
  {boom: 1}   the mod's handler fails: answered with {err: its error}, and after 10 within a minute
              the channel is closed for the client's session (link.lua failed)
Other channels and mods are dropped, as the bridge drops them.
"""

import protocol

LINK_VERSION = 1
MOD = "zenith-link-test"
WINDOW = 60
MAX_MESSAGES = 60
MAX_WINDOW_BYTES = 32768
MAX_ERRORS = 10
ERROR_WINDOW = 3600


def welcome_fields(welcome):
    welcome["ext"] = LINK_VERSION
    welcome.setdefault("mods", {})[MOD] = "mock"


def _counted(game, way, nbytes):
    """The bridge's caps (link.lua counted), per client, in and out apart."""
    link = game.client.get("link")
    if link is None or game.tick - link["w"] >= WINDOW or game.tick < link["w"]:
        link = game.client["link"] = {"w": game.tick, "i": 0, "ib": 0, "o": 0, "ob": 0}
    if link[way] + 1 > MAX_MESSAGES or link[way + "b"] + nbytes > MAX_WINDOW_BYTES:
        return False
    link[way] += 1
    link[way + "b"] += nbytes
    return True


def send(game, channel, data):
    """The mod's remote.call("zenith", "send", ...): True when sent."""
    msg = {"t": "ext", "k": game.tick, "ch": channel, "d": data}
    nbytes = protocol.ext_bytes(msg)
    if game.client is None or nbytes > protocol.EXT_MAX_BYTES or not _counted(game, "o", nbytes):
        return False
    game.send_now(msg)
    return True


def _failed(game, channel, text):
    """A companion's handler failed (link.lua failed): the error back on its channel, the channel
    closed after MAX_ERRORS within ERROR_WINDOW ticks."""
    game.send_now({"t": "ext", "k": game.tick, "ch": channel, "err": text})
    errs = game.client.setdefault("link_err", {})
    e = errs.get(channel)
    if e is None or game.tick - e["w"] >= ERROR_WINDOW or game.tick < e["w"]:
        e = errs[channel] = {"w": game.tick, "n": 0}
    e["n"] += 1
    if e["n"] >= MAX_ERRORS:
        del errs[channel]
        game.client.setdefault("link_closed", set()).add(channel)
        game.send_now({"t": "ext", "k": game.tick, "ch": channel,
                       "err": f"closed after repeated errors ({MAX_ERRORS} within {ERROR_WINDOW // 60} s)"})


def command(game, t, msg):
    """Handles `ext`; False for any other command."""
    if t != "ext":
        return False
    ch, d = msg.get("ch"), msg.get("d")
    if (not protocol.ext_channel_ok(ch) or d is None or ch.partition("/")[0] != MOD
            or ch in game.client.get("link_closed", ())
            or protocol.ext_bytes(msg) > protocol.EXT_MAX_BYTES or not _counted(game, "i", protocol.ext_bytes(msg))):
        return True
    if isinstance(d, dict) and d.get("boom"):
        _failed(game, ch, "__zenith-link-test__/control.lua:42: linktest: boom, as asked")
    if isinstance(d, dict) and "echo" in d:
        send(game, ch, {"echo": d["echo"]})
    elif isinstance(d, dict) and isinstance(d.get("burst"), int) and not isinstance(d["burst"], bool):
        for i in range(1, max(0, min(d["burst"], 1000)) + 1):
            send(game, ch, {"i": i})
    elif isinstance(d, dict) and d.get("who") == 1:
        send(game, ch, {"client": game.client["addr"][1], "unit": game.player["unit"]})
    return True
