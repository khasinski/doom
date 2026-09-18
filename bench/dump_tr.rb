# Render the real DOOM frame headlessly (no Gosu window) and dump a PPM, so the
# frame can be viewed. Runs on any runtime incl. TruffleRuby.
%w[wad/reader wad/palette wad/colormap wad/flat wad/patch wad/texture wad/sprite
   map/data game/player_state game/animations render/renderer].each { |f| require "doom/#{f}" rescue LoadError }
module Doom; module Game
  class PlayerState; VIEWHEIGHT=41 unless defined?(VIEWHEIGHT); end
  class Player; end unless defined?(Player)
  module MonsterAI; ATTACK_FRAME_TICS=1; ATTACK_FRAMES={}; end unless defined?(MonsterAI)
end; end
require "doom/game/animations"; require "doom/render/renderer"
wad=Doom::Wad::Reader.new("doom1.wad")
pal=Doom::Wad::Palette.load(wad);cm=Doom::Wad::Colormap.load(wad);fl=Doom::Wad::Flat.load_all(wad)
tx=Doom::Wad::TextureManager.new(wad);sp=Doom::Wad::SpriteManager.new(wad)
an=Doom::Game::Animations.new(tx.texture_names, fl.map(&:name))
map=Doom::Map::MapData.load(wad,"E1M1"); ps=map.player_start
r=Doom::Render::Renderer.new(wad,map,tx,pal,cm,fl,sp,an)
r.set_player(ps.x,ps.y,41,ps.angle)
5.times { r.render_frame }
fb=r.framebuffer; ck=fb.map{|v|v||0}.sum
warn "TruffleRuby rendered real frame: checksum=#{ck} nonzero=#{fb.count{|v|v&&v!=0}}"
colors=pal.colors
File.open("bench/tr_frame.ppm","wb"){|io| io.write("P6\n320 240\n255\n"); buf=+""; fb.each{|i| rr,gg,bb=colors[i||0]; buf<<rr.chr<<gg.chr<<bb.chr}; io.write(buf)}
