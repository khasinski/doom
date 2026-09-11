# Modern renderers

Renderers can be selected at startup:

```sh
bin/doom --renderer=classic doom1.wad
bin/doom --renderer=rasterizer doom1.wad
bin/doom --renderer=raytracing doom1.wad
```

During play, `R` cycles through `classic`, `rasterizer`, and `raytracing`
without restarting the simulation. The software `zbuffer` backend remains
available from the command line for development and comparison.

## Hardware rasterizer

The rasterizer converts BSP subsectors, sector planes and linedefs to ordinary
triangles. It renders them through Gosu's OpenGL context with a depth buffer,
WAD textures, animated flats, billboard sprites and alpha-tested two-sided
middle textures such as grates.

## GPU ray tracer

The ray tracer sends world triangles and a stackless BVH to floating-point GPU
textures. A GLSL fragment shader traces primary visibility and hard shadow rays
at 640×480, then scales the result to the window. This is GPU-accelerated
software ray tracing; it does not require hardware ray-intersection units.

It supports:

- textured walls, floors, ceilings and Doom's sky projection;
- animated flats and wall textures;
- dynamic point lights and BVH-traced shadows;
- emissive nukage/slime sectors;
- optional distance fog and a shadowed flashlight (`Options` menu);
- lit and fogged rasterized sprites with depth-tested world occlusion;
- alpha-tested grates for both primary and shadow rays;
- BVH refitting for moving doors and lifts without rebuilding static textures.

Sprite pixels are still a hybrid raster pass rather than ray-traced geometry.
Reflections and indirect light bounces are not implemented.
