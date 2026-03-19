# DOOM Ruby

A faithful port of the DOOM (1993) engine to pure Ruby. Renders the original WAD files with near pixel-perfect BSP rendering, full HUD, item pickups, and hitscan/projectile combat.

![DOOM Ruby](demo.gif)

## Features

- **Rendering**: BSP traversal, visplanes, drawsegs, sprite clipping, sky rendering matching Chocolate Doom
- **Combat**: Hitscan weapons (pistol, shotgun, chaingun), melee (fist, chainsaw), projectile rockets with splash damage
- **Items**: Weapons, ammo, health, armor, keys -- all pickupable with correct DOOM behavior
- **Movement**: Momentum-based physics with friction, smooth step transitions, wall sliding, view bob
- **HUD**: Full status bar with ammo, health, armor, face, weapon selector, key cards, small ammo counts
- **Effects**: Animated textures (NUKAGE, SLADRIP), sector light effects (flickering, glowing, strobing), scrolling walls
- **Monsters**: Death animations, solid collision, HP tracking
- **Compatibility**: Supports original WAD files (shareware and registered), YJIT-optimized

## Installation

```bash
gem install doom
```

## Quick Start

Just run `doom` -- it will offer to download the free shareware version:

```bash
doom
```

Or specify your own WAD file:

```bash
doom /path/to/doom.wad
```

## Controls

| Key | Action |
|-----|--------|
| W / Up Arrow | Move forward |
| S / Down Arrow | Move backward |
| A | Strafe left |
| D | Strafe right |
| Left Arrow | Turn left |
| Right Arrow | Turn right |
| Mouse | Look around (click to capture) |
| Left Click / X / Shift | Fire weapon |
| Space / E | Use (open doors) |
| 1-7 | Switch weapons |
| M | Toggle automap |
| Z | Toggle debug overlay |
| Escape | Release mouse / Quit |

## Requirements

- Ruby 3.1+ (Ruby 4.0 with YJIT recommended for best performance)
- Gosu gem (for window/graphics)
- SDL2 (native library required by Gosu)

### Installing SDL2

**macOS:**
```bash
brew install sdl2
```

**Ubuntu/Debian:**
```bash
sudo apt-get install build-essential libsdl2-dev libgl1-mesa-dev libopenal-dev libsndfile1-dev libmpg123-dev libfontconfig1-dev
```

**Fedora:**
```bash
sudo dnf install SDL2-devel mesa-libGL-devel fontconfig-devel gcc-c++
```

**Arch Linux:**
```bash
sudo pacman -S sdl2 mesa
```

**Windows:**
No additional setup needed -- the gem includes SDL2.

## Development

```bash
git clone https://github.com/khasinski/doom.git
cd doom
bundle install
ruby bin/doom
```

Run specs:

```bash
bundle exec rspec
```

### Benchmarking

```bash
ruby bench/benchmark.rb                     # without YJIT
ruby --yjit bench/benchmark.rb              # with YJIT
ruby bench/benchmark.rb --compare           # side-by-side
ruby bench/benchmark.rb --profile           # CPU profile with StackProf
```

## Technical Details

- **BSP Traversal**: Front-to-back rendering using the map's BSP tree with R_CheckBBox culling
- **Visplanes**: Floor/ceiling rendering with R_CheckPlane splitting and span-based drawing
- **Drawsegs**: Wall segment tracking for proper sprite clipping (silhouette system)
- **Texture Mapping**: Perspective-correct ray-seg intersection with non-power-of-2 support
- **Lighting**: Distance-based light diminishing with wall and flat colormaps
- **Sky Rendering**: Chocolate Doom sky hack (worldtop = worldhigh) with correct placement
- **Movement Physics**: Continuous-time momentum/friction matching Chocolate Doom's P_XYMovement
- **Hitscan**: Ray tracing against walls and monster bounding circles
- **Projectiles**: Physical rockets with wall/monster collision and splash damage

## Performance

With Ruby 4.0 and YJIT enabled, the renderer achieves 80-130 FPS on E1M1 (Apple Silicon). See [docs/performance-profiling.md](docs/performance-profiling.md) and [docs/yjit-vs-zjit.md](docs/yjit-vs-zjit.md) for detailed analysis.

## Legal

DOOM is a registered trademark of id Software LLC. This is an unofficial fan project.

The shareware version of DOOM (Episode 1) is freely distributable. For the full game,
please purchase DOOM from [Steam](https://store.steampowered.com/app/2280/Ultimate_Doom/),
[GOG](https://www.gog.com/pl/game/doom_doom_ii), or other retailers.

## License

GPL-2.0 -- Same license as the original DOOM source code.

## Author

Chris Hasinski ([@khasinski](https://github.com/khasinski))
