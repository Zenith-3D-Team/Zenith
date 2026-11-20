# Sprint (a Zenith add-on and its Factorio mod)

Hold **Shift** to run faster. A worked example of the one way an add-on changes the game: through a
Factorio mod of its own that everyone in the game has. Needs Zenith's add-on API 1.7 (`api.game`,
docs/ADDONS.md, "Messages to your Factorio mod").

- `addon.json`, `main.gd`: the add-on. A control "Sprint (hold)" in Settings → Controls (Shift by
  default; any key can be bound there). While it is held it sends `{on: true}` on the channel
  `zenith-sprint`, again every half second; let go, `{on: false}`. Without the mod in the game it
  says so once and sends nothing.
- `mod/zenith-sprint/`: the Factorio mod. It adds its bonus to the character's
  `character_running_speed_modifier` and takes the same amount off again (so other mods' changes
  survive) on "off", when the character is gone, or 1.5 s after the last "on". The bonus is a map
  setting (Settings → Mod settings → Map, "Sprint bonus", 0.5 by default), so the server's owner
  decides it and every player has the same.

## Installing

1. Put `mod/zenith-sprint` in Factorio's mods folder (for a server, the server's), beside Zenith's
   bridge mod, and switch it on. Everyone who joins that game gets it from the server as with any mod.
2. Put this folder (without `mod/`, or as it is) in Zenith's `addons` folder and switch Sprint on in
   the Add-ons menu.

Holding Shift also runs while Shift is held for Zenith's own Shift+click controls; bind Sprint to
another key in Settings → Controls if that gets in the way.

Not bundled with Zenith and not on Factorio's mod portal. Licence: to be decided.
