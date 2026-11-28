# Licensing

Zenith is free software: you can redistribute it and/or modify it under the terms of the GNU
General Public License, version 3 ([LICENSE](LICENSE)). It comes with no warranty.

Copyright (c) 2026 Zenith contributors

Zenith 0.1.0 was released under the MIT licence, and that release stays MIT. From 0.1.1 on,
Zenith is GPL-3.0.

## What the GPL covers

Zenith's own code, scripts, shaders, docs and the models its tools generate: the bridge mod, the
client, the server scripts and the tools. If you share a modified version of Zenith, you share
its source under the GPL too.

## Add-on exception

Additional permission under GNU GPL version 3 section 7:

As a special exception, the copyright holders of Zenith give you permission to write, use and
distribute add-ons for Zenith under terms of your choice. An add-on here is a folder or zip with
an `addon.json` that Zenith's add-on loader loads, and that works with Zenith only through the
add-on API (`client/scripts/addons/`, described in [docs/ADDONS.md](docs/ADDONS.md)). This
permission doesn't cover add-ons that contain code copied from Zenith, or modified versions of
Zenith itself, which stay under the GPL.

## Vendor upscaler exception

Additional permission under GNU GPL version 3 section 7:

As a special exception, the copyright holders of Zenith give you permission to combine Zenith with
the vendor runtime libraries listed below, by loading them at run time through the programming
interfaces their vendors publish, and to convey the result with those libraries in the unmodified
binary form their vendors publish. Those libraries are not covered by the GPL, their source code is
not part of Zenith's Corresponding Source, and they keep their own licences, which are shipped
beside them:

- AMD FSR SDK signed runtime libraries (`amd_fidelityfx_*.dll`), under AMD's FSR SDK licence
  (its `license.md` is shipped beside them in `vendor/amd/`);
- NVIDIA DLSS and NVIDIA Streamline runtime libraries (`nvngx_*.dll`, `sl.*.dll`), under the NVIDIA
  RTX SDKs License and Streamline's licence. Zenith does not ship these: you get them from NVIDIA
  and put them in `vendor/nvidia/` yourself, and this permission covers Zenith loading them there.

This permission covers those libraries only. Zenith's own code that calls them stays under the GPL,
with its full source. Zenith works without them: delete the `vendor` folder and the matching
Upscaling choices switch off. If you change Zenith you may keep this exception for your version or
remove it.

## Not covered by the GPL

These keep their own terms. They are separate works shipped alongside Zenith:

- **A Windows download's `vendor/` folder** (AMD's FSR runtime libraries; NVIDIA's DLSS and
  Streamline files if you put them there yourself, never shipped by Zenith): © Advanced Micro
  Devices, Inc. and © NVIDIA Corporation. Closed-source, under their own licences (AMD's
  `license.md` is in the folder); you may not reverse engineer them or pass them on apart from Zenith.
- **`client/assets/branding/`** (Zenith's logo and icon, `client/icon.png`, `client/icon.ico`):
  © David (Vasillo). Used in Zenith with his permission; see the folder's README.
- **A download's `models/Zenith.zip`**, the Zenith model pack (the development builds carry
  David's (Vasillo's) textured belts, splitters, undergrounds, inserters and burner drill in it):
  © David (Vasillo). Used in Zenith with his permission; its `pack.json` and README.txt say so.
- **`client/assets/models/packs/fue5/`**, the FUE5 model pack: models by Hurricane and Nuke
  (FUE5), CC BY-NC-SA 3.0; see its README.
- **`client/assets/models/packs/wube3dp/`**, the Wube3DP model pack: models converted from Wube's
  printable release (listed in
  [client/assets/models/packs/wube3dp/CREDITS.md](client/assets/models/packs/wube3dp/CREDITS.md)),
  under Wube's CC BY-NC licence.
- **`addons-src/immersive-weather/sounds/`** (wind, rain and thunder audio clips):
  from *Weather Elements* by Helton Yan (https://heltonyan.itch.io/weatherelements), CC BY 4.0;
  see [addons-src/immersive-weather/CREDITS.md](addons-src/immersive-weather/CREDITS.md).
- **Factorio** itself and its graphics, sounds and fonts are © Wube Software and aren't part of
  Zenith: the client reads them from your own Factorio install.

[CREDITS.md](CREDITS.md) has the details and everyone credited.
