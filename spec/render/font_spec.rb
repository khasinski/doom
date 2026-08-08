# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/doom/render/font'

RSpec.describe Doom::Render::Font do
  # A glyph exposing just the surface Font touches: a width and per-column
  # pixel arrays (indexed [col_x][col_y], nil = transparent).
  FakeSprite = Struct.new(:width, :columns) do
    def column_pixels(col_x)
      columns[col_x]
    end
  end

  # Stands in for HudGraphics: Font asks it for "STCFN%03d" patches by ascii.
  class FakeGraphics
    def initialize(glyphs)
      @glyphs = glyphs
    end

    def load_graphic(name)
      @glyphs[name]
    end
  end

  # 'A' (ascii 65) => a 3-wide glyph, two rows tall: row0 = color 1, row1 = 2.
  let(:glyph_a) { FakeSprite.new(3, [[1, 2], [1, 2], [1, 2]]) }
  let(:graphics) { FakeGraphics.new('STCFN065' => glyph_a) }
  let(:font) { described_class.new(nil, graphics) }

  describe '#text_width' do
    it 'sums glyph widths' do
      expect(font.text_width('A')).to eq(3)
      expect(font.text_width('AA')).to eq(6)
    end

    it 'counts spaces as SPACE_WIDTH' do
      expect(font.text_width('A A')).to eq(3 + described_class::SPACE_WIDTH + 3)
    end

    it 'auto-uppercases lowercase input' do
      expect(font.text_width('a')).to eq(font.text_width('A'))
    end

    it 'ignores characters with no glyph loaded' do
      expect(font.text_width('AZA')).to eq(6)
    end
  end

  describe '#draw_text' do
    it 'writes glyph pixels into the framebuffer and returns the width drawn' do
      w = 10
      h = 4
      fb = Array.new(w * h, 0)

      drawn = font.draw_text(fb, 'A', 0, 0, screen_width: w, screen_height: h)

      expect(drawn).to eq(3)
      # Row 0 columns 0..2 = color 1, row 1 columns 0..2 = color 2.
      expect(fb[0, 3]).to eq([1, 1, 1])
      expect(fb[w, 3]).to eq([2, 2, 2])
      # Column 3 onward untouched.
      expect(fb[3]).to eq(0)
    end

    it 'honours the x/y offset' do
      w = 10
      h = 4
      fb = Array.new(w * h, 0)

      font.draw_text(fb, 'A', 2, 1, screen_width: w, screen_height: h)

      expect(fb[w * 1 + 2, 3]).to eq([1, 1, 1])
      expect(fb[w * 2 + 2, 3]).to eq([2, 2, 2])
    end

    it 'clips pixels outside the screen bounds' do
      w = 4
      h = 4
      fb = Array.new(w * h, 0)

      # Start near the right edge: only the first two columns fit.
      drawn = font.draw_text(fb, 'A', 2, 0, screen_width: w, screen_height: h)

      expect(drawn).to eq(3) # advance still counts the full glyph
      expect(fb[0, 4]).to eq([0, 0, 1, 1]) # columns 2,3 drawn; column 4 clipped away
    end
  end

  describe '#draw_centered' do
    it 'centres the text horizontally' do
      w = 11
      h = 4
      fb = Array.new(w * h, 0)

      font.draw_centered(fb, 'A', 0, screen_width: w, screen_height: h)

      # width 3 centred in 11 => x = (11 - 3) / 2 = 4
      expect(fb[4, 3]).to eq([1, 1, 1])
    end
  end
end
