# Credits and Licence — Immersive Weather

Immersive Weather's scripts, shaders and manifest (`main.gd`, `scripts/*.gd`, `shaders/*.gdshader`, `addon.json`, docs) follow Zenith's GNU GPL, version 3 ([LICENSE](../../LICENSE); [LICENSING.md](../../LICENSING.md)).

## Storm wind (generated)

The storm wind's roar and gusts (0.3.2, `scripts/storm_wind.gd`) are noise made by the add-on's own code when the game starts: no recording, nothing downloaded; GPL-3.0 as the scripts. `sounds/wind-gusty.ogg` (below) is still played as a quiet layer at the top of strong gusts, and in full with the Classic storm wind.

## Weather Audio (`sounds/*.ogg`)

All sound effects in `sounds/` come from **Weather Elements** (`FREE WEATHER SFX - Rain, Wind and Thunder`) by **Helton Yan**:

- **Source:** https://heltonyan.itch.io/weatherelements
- **Author:** Helton Yan
- **Licence:** Creative Commons Attribution 4.0 International (**CC BY 4.0**) — https://creativecommons.org/licenses/by/4.0/
- **Changes made:** Selected stereo 44.1 kHz WAV recordings were trimmed (2 s equal-power crossfades into 18 s loops for wind and rain; trimmed trailing silence and cosine fade-outs for thunder one-shots), loudness-normalized, and encoded to Ogg Vorbis. The audio files remain under **CC BY 4.0**.

### Source File Mapping

| Bundled File | Original File in Weather Elements | Type |
| --- | --- | --- |
| `sounds/wind-gentle.ogg` | `WE Light Wind Whistle 4.wav` | 18 s seamless loop |
| `sounds/wind-gusty.ogg` | `WE Heavy Wind Whistle 7.wav` | 18 s seamless loop |
| `sounds/rain-light.ogg` | `WE Light Outside Rain 1.wav` | 18 s seamless loop |
| `sounds/rain-steady.ogg` | `WE Light Outside Rain 5.wav` | 18 s seamless loop |
| `sounds/rain-heavy.ogg` | `WE Heavy Outside Rain 2.wav` | 18 s seamless loop |
| `sounds/thunder-crack-1.ogg` | `WE Thunder 1.wav` | Trimmed one-shot |
| `sounds/thunder-crack-2.ogg` | `WE Thunder 3.wav` | Trimmed one-shot |
| `sounds/thunder-crack-3.ogg` | `WE Thunder 13.wav` | Trimmed one-shot |
| `sounds/thunder-crack-4.ogg` | `WE Thunder 16.wav` | Trimmed one-shot |
| `sounds/thunder-roll-1.ogg` | `WE Thunder 7.wav` | Trimmed one-shot |
| `sounds/thunder-roll-2.ogg` | `WE Thunder 19.wav` | Trimmed one-shot |
| `sounds/thunder-roll-3.ogg` | `WE Thunder 23.wav` | Trimmed one-shot |
| `sounds/thunder-roll-4.ogg` | `WE Thunder 26.wav` | Trimmed one-shot |
