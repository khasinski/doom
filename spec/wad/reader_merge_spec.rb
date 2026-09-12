# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'

# Self-contained (no real IWAD needed): builds tiny synthetic WADs in memory to
# exercise PWAD merging, which the real-WAD specs never touch. The one property
# that matters here is that a lump the PWAD overrides is read from the PWAD file,
# not from the base IWAD's handle at the same offset.
RSpec.describe 'Doom::Wad::Reader PWAD merge' do
  after { @tempfiles&.each { |t| t.close! } }

  # lumps: [[name, bytes], ...]. Returns the path to a WAD file on disk.
  def wad_path_for(type, lumps)
    header_size = 12
    body = +''.b
    directory = +''.b
    offset = header_size
    lumps.each do |name, bytes|
      chunk = bytes.b
      body << chunk
      directory << [offset, chunk.bytesize].pack('VV') << [name.b[0, 8]].pack('a8')
      offset += chunk.bytesize
    end
    dir_offset = header_size + body.bytesize
    wad = type.b + [lumps.size, dir_offset].pack('VV') + body + directory

    file = Tempfile.new(['wad', '.wad'])
    file.binmode
    file.write(wad)
    file.flush
    (@tempfiles ||= []) << file
    file.path
  end

  it 'reads an overridden non-map lump from the PWAD, not the base IWAD offset' do
    iwad = Doom::Wad::Reader.new(
      wad_path_for('IWAD', [%w[PLAYPAL IWAD-PALETTE-DATA], %w[COLORMAP iwad-colormap]])
    )
    pwad = Doom::Wad::Reader.new(
      wad_path_for('PWAD', [%w[PLAYPAL PWAD-OVERRIDE-PAL]])
    )

    iwad.merge_pwad(pwad)

    # The override must come from the PWAD file. Before the fix, read_lump seeked
    # the IWAD handle at the PWAD entry's offset and returned garbage.
    expect(iwad.read_lump('PLAYPAL')).to eq('PWAD-OVERRIDE-PAL'.b)
    # A lump the PWAD did not touch still reads correctly from the IWAD.
    expect(iwad.read_lump('COLORMAP')).to eq('iwad-colormap'.b)

    iwad.close
    pwad.close
  end

  it 'appends a PWAD-only lump and reads it from the PWAD file' do
    iwad = Doom::Wad::Reader.new(wad_path_for('IWAD', [%w[PLAYPAL base-pal]]))
    pwad = Doom::Wad::Reader.new(wad_path_for('PWAD', [%w[NEWLUMP brand-new-lump]]))

    iwad.merge_pwad(pwad)

    expect(iwad.read_lump('NEWLUMP')).to eq('brand-new-lump'.b)
    expect(iwad.read_lump('PLAYPAL')).to eq('base-pal'.b)

    iwad.close
    pwad.close
  end
end
