# Modern renderer

The experimental `zbuffer` renderer can be selected at startup:

```sh
bin/doom --renderer=zbuffer doom1.wad
```

Press `R` during play to switch between `classic` and `zbuffer` without
restarting the game. The active renderer is printed to the terminal.

The hardware 3D path is selected with `--renderer=rasterizer`. In this mode
`R` switches directly between the classic renderer and the GPU rasterizer.

The ray-tracing development path starts with `--renderer=raytracing`. It is an
isolated renderer entry point derived from the working GPU rasterizer; until
ray passes are added, its output is intentionally identical. During play, `R`
cycles through `classic`, `rasterizer`, and `raytracing`.

## Implemented

- a separate renderer selected through `RendererFactory`;
- a 320×240 floating-point depth buffer populated by opaque wall geometry;
- dynamic lights attached to projectiles and explosions;
- ray-traced hard visibility shadows: wall samples cast rays toward dynamic
  lights, and one-sided linedefs occlude those rays;
- palette-aware warm additive lighting;
- renderer selection survives level changes and works for network clients.

## Current limits

This is the first vertical slice, not a GPU renderer. The BSP renderer still
determines visibility. Dynamic direct light currently shades opaque walls;
floors, ceilings, sprites, masked textures, portal-height-aware shadows,
reflections, and secondary light bounces are not implemented yet. Rays run on
the CPU against linedefs, so dense maps with many simultaneous lights will need
a spatial acceleration structure before raising the light limit.

The next useful steps are to triangulate sector floors/ceilings, move all
geometry through depth-tested fragments, add a blockmap/BVH for shadow rays,
then introduce a GPU backend with the same renderer interface. That gives a
sound route to reflections and indirect lighting without coupling rendering to
game simulation.
