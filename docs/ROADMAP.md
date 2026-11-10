# Zenith: Roadmap

Where Zenith is going, may not happen in this exact order but a general idea of my plans for the project.
[Releases](https://github.com/unjustodin/Zenith/releases),
[Issues](https://github.com/unjustodin/Zenith/issues).

## Goals, not one milestone at a time

The road to 1.0 is six goals, each with a priority. Work goes on several of them at once: the
priority says what wins when two things compete for time, not that a goal waits until the one
above it is finished. A release ships whatever is ready across all of them.

| Priority | Goal | In short |
|---|---|---|
| 1 | [Stability](#1-stability) | Works on real games and big saves, bugs fixed first |
| 2 | [Performance](#2-performance) | 60 UPS and a smooth frame rate on big bases |
| 3 | [Interface](#3-interface) | Factorio's interface and controls, 1:1 |
| 4 | [Models and animation](#4-models-and-animation) | Every model true to its sprite, and moving as in the game |
| 5 | [Space Age](#5-space-age) | Platforms, rockets, planets and their creatures finished |
| 6 | [Mods and add-ons](#6-mods-and-add-ons) | Other Factorio mods drawn, and more open to add-ons |

**1.0** comes when all six are met and everything you can do in Factorio, you can do in Zenith.

## Version numbers

Versions are `state.release.hotfix`:

- **State:** 0 while Zenith is in development, 1 from the full release.
- **Release:** the second number counts feature releases. Each one carries progress on any of the
  goals; it isn't tied to one goal.
- **Hotfix:** the third number is for bug fixes between releases, with no new features. There's
  no limit: 0.1.100 comes after 0.1.99.

The bridge mod and the client always carry the same version. The add-ons keep their own numbers.

## The goals

### 1. Stability

Everything that works against the test server checked on real games and real saves, and the bugs
that turns up fixed:

- Players' bug reports, always first.
- Trains on elevated rails, and train stops in the colour you paint them.
- Several Zenith players on one server, side by side.
- Switching a running game between Factorio's window and Zenith (Ctrl+F9).
- Long sessions on big saves; the Linux server script and download.

### 2. Performance

- Forests and long view distances, which cost the graphics card the most today.
- Simpler stand-ins for far trees and far chunks.
- 60 UPS on very big bases with less held back from what you see.
- A smooth frame rate while running, at long view distances too.

### 3. Interface

- Factorio's interface matched 1:1: the last differences in layout and behaviour.
- Train and platform schedules that look and feel like Factorio's own.
- The map view, alerts, Factoriopedia and tooltips as Factorio has them; Tips and tricks with
  their pictures.
- The camera views (Factorio's angle, first person, the map's remote view) finished.
- Smaller things: dragging undergrounds, pipes and poles, crafting that shows at once, what's
  inside a chest when you hover it.

### 4. Models and animation

- Models that still differ from their Factorio sprites redone, and more textured models where
  they're better than ours (with help from modellers: [MODELLERS.md](MODELLERS.md)).
- 3D foliage, and wind in trees and plants.
- The buildings, vehicles and creatures still missing animations, the moving parts some
  textured models lost, the rocket silo's launch.
- The character's run, and the lights at night.
- Shader work: better shadows and lighting in general (softer, steadier shadows, light on the
  models' materials, ambient light and occlusion cheap enough to leave on).

### 5. Space Age

- Flying up to and past planets, rockets and cargo pods.
- Space platforms and travel as in the game.
- Each planet's sky, ground and details; Space Age's enemies finished.

### 6. Mods and add-ons

- Other mods' buildings, items and ground drawn from their own graphics, and model packs for them.
- Big overhaul mods tried and working.
- More of the client open to add-ons, as add-on authors need it.

## Released

### 0.1: First release

Real Factorio 2.1 (with or without Space Age) played in 3D: a model for every base game and
Space Age entity, Factorio's own interface and hotkeys, your own saves, space platforms and the
other planets, add-ons. Hotfixes on 0.1 (0.1.1, 0.1.2) fixed the bugs players reported and made
big bases faster.
