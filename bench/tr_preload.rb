# Preload homebrew SDL2 into the process (global) so Gosu's flat-namespace
# native extension resolves SDL symbols on TruffleRuby, whose gosu build does
# not link SDL2 itself. Harmless on other runtimes.
begin
  require "fiddle"
  ["/opt/homebrew/lib/libSDL2-2.0.0.dylib", "/opt/homebrew/lib/libSDL2.dylib"].each do |p|
    (Fiddle.dlopen(p); break) if File.exist?(p)
  end
rescue StandardError => e
  warn "tr_preload: #{e.class}: #{e.message}"
end
