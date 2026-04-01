#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates a standalone WAD with a two-sector demo map for presentation screenshots.
# Copies asset lumps (palette, colormaps, textures, flats, sprites) from doom1.wad
# and builds a custom E1M1 map.
#
# Layout (top-down, Y+ is north):
#
#   V3 --------- V2 --------- V5
#   |             |             |
#   |  Sector 0   |  Sector 1   |
#   |  floor=0    |  floor=48   |
#   |  ceil=128   |  ceil=104   |
#   |  BROWN96    |  COMPTALL   |
#   |  FLOOR4_8   |  FLAT14     |
#   |             |             |
#   V0 --------- V1 --------- V4
#
#   Player starts in Sector 0, facing East toward the portal.
#
# Right sidedef = the side to your RIGHT when walking from V1 to V2.
# Right normal of direction (dx,dy) = (dy, -dx).
# For a room, linedefs must wind so right sidedef faces INWARD.

require_relative '../lib/doom/wad/reader'

IWAD_PATH = ARGV[0] || 'doom1.wad'
OUTFILE   = ARGV[1] || 'demo.wad'

abort "Cannot find #{IWAD_PATH}" unless File.exist?(IWAD_PATH)

# --- Map geometry ---

ROOM_W = 512
ROOM_H = 384
HH = ROOM_H / 2  # half height

# Vertices
#   V0=(-512,-192)  V1=(0,-192)  V4=(512,-192)
#   V3=(-512, 192)  V2=(0, 192)  V5=(512, 192)
VERTICES = [
  [-ROOM_W, -HH],  # V0
  [0,       -HH],  # V1
  [0,        HH],  # V2
  [-ROOM_W,  HH],  # V3
  [ROOM_W,  -HH],  # V4
  [ROOM_W,   HH],  # V5
]

# Sectors: [floor_h, ceil_h, floor_tex, ceil_tex, light]
SECTORS = [
  [0,   128, 'FLOOR4_8', 'CEIL3_5', 200],  # S0 - brown room
  [48,  104, 'FLAT14',   'CEIL5_1', 160],  # S1 - green/tech room, raised floor, lower ceiling
]

# Sidedefs: [x_off, y_off, upper_tex, lower_tex, mid_tex, sector]
SIDEDEFS = [
  # Sector 0 outer walls (one-sided, right side faces inward)
  [0, 0, '-', '-', 'BROWN96', 0],   # SD0: S0 south wall
  [0, 0, '-', '-', 'BROWN96', 0],   # SD1: S0 west wall
  [0, 0, '-', '-', 'BROWN96', 0],   # SD2: S0 north wall

  # Portal: two-sided linedef between S0 and S1
  # Linedef goes V1->V2 (south to north), right side faces EAST (sector 1)
  # From S1 side: upper wall where S0 ceiling is higher, lower wall where S1 floor is higher
  [0, 0, '-',       '-',     '-', 1],   # SD3: portal RIGHT side (sector 1, east side)
  [0, 0, 'BROWN96', 'STEP4', '-', 0],   # SD4: portal LEFT side (sector 0, west side) - has upper+lower

  # Sector 1 outer walls (one-sided)
  [0, 0, '-', '-', 'COMPTALL', 1],  # SD5: S1 south wall
  [0, 0, '-', '-', 'COMPTALL', 1],  # SD6: S1 east wall
  [0, 0, '-', '-', 'COMPTALL', 1],  # SD7: S1 north wall
]

# Linedefs: [v1, v2, flags, special, tag, right_sd, left_sd]
# For each linedef, right normal = (dy, -dx) must point INTO the sector of right_sd.
#
# Sector 0 walls (clockwise winding when viewed from inside / CCW from above with Y+ up):
#   South: V1->V0, dir=(-1,0), right_normal=(0,1)=north -> into S0 ✓
#   West:  V0->V3, dir=(0,1),  right_normal=(1,0)=east  -> into S0 ✓
#   North: V3->V2, dir=(1,0),  right_normal=(0,-1)=south -> into S0 ✓
#
# Portal: V1->V2, dir=(0,1), right_normal=(1,0)=east -> into S1 (right=S1, left=S0)
#
# Sector 1 walls:
#   South: V1->V4, dir=(1,0),  right_normal=(0,-1)=south -> WRONG! Need V4->V1
#   Correct:
#   South: V4->V1, dir=(-1,0), right_normal=(0,1)=north  -> into S1 ✓
#   East:  V5->V4, dir=(0,-1), right_normal=(-1,0)=west  -> into S1 ✓
#   North: V2->V5, dir=(1,0),  right_normal=(0,-1)=south -> into S1 ✓

BLOCKING = 1
TWOSIDED = 4

LINEDEFS = [
  [1, 0, BLOCKING, 0, 0, 0, -1],   # LD0: S0 south (V1->V0)
  [0, 3, BLOCKING, 0, 0, 1, -1],   # LD1: S0 west  (V0->V3)
  [3, 2, BLOCKING, 0, 0, 2, -1],   # LD2: S0 north (V3->V2)
  [1, 2, TWOSIDED, 0, 0, 3,  4],   # LD3: portal   (V1->V2), right=S1, left=S0
  [4, 1, BLOCKING, 0, 0, 5, -1],   # LD4: S1 south (V4->V1)
  [5, 4, BLOCKING, 0, 0, 6, -1],   # LD5: S1 east  (V5->V4)
  [2, 5, BLOCKING, 0, 0, 7, -1],   # LD6: S1 north (V2->V5)
]

# Things
THINGS = [
  [-ROOM_W / 2, 0, 0, 1, 7],  # Player 1 start, facing east (angle=0)
]

# --- BSP ---
# Partition line along the portal: from V1(0,-192) going north, dir=(0,384)
# point_on_side for player at (-256,0):
#   dx=-256, dy=192, left=dy*node.dx=192*0=0, right=dx*node.dy=-256*384<0
#   right < left -> side=1 (left child)
# So left_child = subsector with sector 0 (where player is)
#    right_child = subsector with sector 1

def seg_angle(v1, v2)
  dx = VERTICES[v2][0] - VERTICES[v1][0]
  dy = VERTICES[v2][1] - VERTICES[v1][1]
  bam = (Math.atan2(dy, dx) * 32768.0 / Math::PI).round
  ((bam + 32768) % 65536) - 32768
end

# Segs follow the same vertex order as linedefs.
# direction=0 means seg goes same direction as linedef (uses right sidedef's sector)
# direction=1 means seg goes opposite direction (uses left sidedef's sector)
SEGS = [
  # Subsector 0 - Sector 0 (left child, west of partition)
  [1, 0, seg_angle(1, 0), 0, 0, 0],  # LD0: south wall (V1->V0), dir=0 -> right sd -> sector 0
  [0, 3, seg_angle(0, 3), 1, 0, 0],  # LD1: west wall  (V0->V3)
  [3, 2, seg_angle(3, 2), 2, 0, 0],  # LD2: north wall (V3->V2)
  [2, 1, seg_angle(2, 1), 3, 1, 0],  # LD3: portal from S0 side, dir=1 -> left sd -> sector 0

  # Subsector 1 - Sector 1 (right child, east of partition)
  [4, 1, seg_angle(4, 1), 4, 0, 0],  # LD4: south wall (V4->V1)
  [5, 4, seg_angle(5, 4), 5, 0, 0],  # LD5: east wall  (V5->V4)
  [2, 5, seg_angle(2, 5), 6, 0, 0],  # LD6: north wall (V2->V5)
  [1, 2, seg_angle(1, 2), 3, 0, 0],  # LD3: portal from S1 side, dir=0 -> right sd -> sector 1
]

SUBSECTORS = [
  [4, 0],  # SS0: 4 segs starting at 0 (sector 0)
  [4, 4],  # SS1: 4 segs starting at 4 (sector 1)
]

NODES = [
  {
    x: 0, y: -HH, dx: 0, dy: ROOM_H,
    # Right bbox (sector 1, east): top, bottom, left, right
    r_bbox: [HH, -HH, 0, ROOM_W],
    # Left bbox (sector 0, west)
    l_bbox: [HH, -HH, -ROOM_W, 0],
    right_child: 0x8000 | 1,  # subsector 1 (sector 1)
    left_child:  0x8000 | 0,  # subsector 0 (sector 0)
  }
]

# --- Binary builders ---

def pack8(name)
  name[0, 8].ljust(8, "\x00")
end

def build_things
  THINGS.map { |x, y, a, t, f| [x, y, a, t, f].pack('s<s<vvv') }.join
end

def build_linedefs
  LINEDEFS.map { |v1, v2, fl, sp, tg, rs, ls| [v1, v2, fl, sp, tg, rs, ls].pack('vvvvvs<s<') }.join
end

def build_sidedefs
  SIDEDEFS.map { |xo, yo, u, l, m, s|
    [xo, yo].pack('s<s<') + pack8(u) + pack8(l) + pack8(m) + [s].pack('v')
  }.join
end

def build_vertices
  VERTICES.map { |x, y| [x, y].pack('s<s<') }.join
end

def build_segs
  SEGS.map { |v1, v2, a, ld, d, o| [v1, v2, a, ld, d, o].pack('vvs<vvs<') }.join
end

def build_subsectors
  SUBSECTORS.map { |c, f| [c, f].pack('vv') }.join
end

def build_nodes
  NODES.map { |n|
    [n[:x], n[:y], n[:dx], n[:dy],
     *n[:r_bbox], *n[:l_bbox],
     n[:right_child], n[:left_child]].pack('s<s<s<s< s<s<s<s< s<s<s<s< vv')
  }.join
end

def build_sectors
  SECTORS.map { |fh, ch, ft, ct, li|
    [fh, ch].pack('s<s<') + pack8(ft) + pack8(ct) + [li, 0, 0].pack('vvv')
  }.join
end

# --- Write WAD ---

def build_wad
  puts "Reading assets from #{IWAD_PATH}..."
  iwad = Doom::Wad::Reader.new(IWAD_PATH)

  lumps = []
  add = ->(name, data) { lumps << [name, data] }

  # Copy essential asset lumps
  %w[PLAYPAL COLORMAP PNAMES TEXTURE1].each do |name|
    data = iwad.read_lump(name)
    if data
      add.call(name, data)
      puts "  Copied #{name} (#{data.bytesize} bytes)"
    end
  end

  # Copy flats
  add.call('F_START', '')
  iwad.lumps_between('F_START', 'F_END').each do |entry|
    add.call(entry.name, iwad.read_lump_at(entry))
  end
  add.call('F_END', '')
  puts "  Copied flats"

  # Copy patches
  p_start = iwad.directory.index { |e| e.name == 'P_START' }
  p_end = iwad.directory.index { |e| e.name == 'P_END' }
  if p_start && p_end
    add.call('P_START', '')
    iwad.directory[p_start + 1...p_end].each do |entry|
      add.call(entry.name, iwad.read_lump_at(entry))
    end
    add.call('P_END', '')
    puts "  Copied patches"
  end

  # Copy sprites
  s_start = iwad.directory.index { |e| e.name == 'S_START' }
  s_end = iwad.directory.index { |e| e.name == 'S_END' }
  if s_start && s_end
    add.call('S_START', '')
    iwad.directory[s_start + 1...s_end].each do |entry|
      add.call(entry.name, iwad.read_lump_at(entry))
    end
    add.call('S_END', '')
    puts "  Copied sprites"
  end

  # Copy HUD graphics (status bar, numbers, faces, weapons, keys)
  hud_names = %w[STBAR STTMINUS STTPRCNT STARMS AMMNUM0 AMMNUM1 AMMNUM2 AMMNUM3 AMMNUM4 AMMNUM5
                  AMMNUM6 AMMNUM7 AMMNUM8 AMMNUM9]
  (0..9).each { |n| hud_names += ["STTNUM#{n}", "STGNUM#{n}", "STYSNUM#{n}"] }
  %w[STKEYS0 STKEYS1 STKEYS2 STKEYS3 STKEYS4 STKEYS5 STFDEAD0 STFGOD0].each { |n| hud_names << n }
  (0..4).each do |h|
    (0..2).each { |f| hud_names << "STFST#{h}#{f}" }
    hud_names += ["STFTL#{h}0", "STFTR#{h}0", "STFOUCH#{h}", "STFEVL#{h}", "STFKILL#{h}"]
  end
  hud_names += %w[PISGA0 PISGB0 PISGC0 PISGD0 PISGE0 PISFA0 PISFB0 PUNGA0 PUNGB0 PUNGC0 PUNGD0]
  hud_count = 0
  hud_names.each do |name|
    data = iwad.read_lump(name)
    if data
      add.call(name, data)
      hud_count += 1
    end
  end
  puts "  Copied #{hud_count} HUD graphics"

  # Custom map
  add.call('E1M1',     '')
  add.call('THINGS',   build_things)
  add.call('LINEDEFS', build_linedefs)
  add.call('SIDEDEFS', build_sidedefs)
  add.call('VERTEXES', build_vertices)
  add.call('SEGS',     build_segs)
  add.call('SSECTORS', build_subsectors)
  add.call('NODES',    build_nodes)
  add.call('SECTORS',  build_sectors)

  iwad.close

  # Write as IWAD
  header_size = 12
  offset = header_size
  directory = []

  lumps.each do |name, data|
    directory << [offset, data.bytesize, name]
    offset += data.bytesize
  end

  File.open(OUTFILE, 'wb') do |f|
    f.write('IWAD')
    f.write([lumps.size, offset].pack('VV'))
    lumps.each { |_, data| f.write(data) }
    directory.each do |off, size, name|
      f.write([off, size].pack('VV'))
      f.write(pack8(name))
    end
  end

  puts ""
  puts "Generated #{OUTFILE} (#{File.size(OUTFILE)} bytes)"
  puts "  #{VERTICES.size} vertices, #{LINEDEFS.size} linedefs, #{SIDEDEFS.size} sidedefs"
  puts "  #{SECTORS.size} sectors, #{SEGS.size} segs, #{SUBSECTORS.size} subsectors, #{NODES.size} nodes"
  puts ""
  puts "Run: ruby --yjit bin/doom #{OUTFILE}"
end

build_wad
