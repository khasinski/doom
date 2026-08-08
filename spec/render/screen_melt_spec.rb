# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/doom/render/screen_melt'

RSpec.describe Doom::Render::ScreenMelt do
  W = Doom::Render::SCREEN_WIDTH
  H = Doom::Render::SCREEN_HEIGHT
  SIZE = W * H

  # old screen = all 0, new screen = all 1, so any pixel in the composite
  # tells us which source it came from.
  let(:old_screen) { Array.new(SIZE, 0) }
  let(:new_screen) { Array.new(SIZE, 1) }

  def build_melt(seed)
    srand(seed)
    described_class.new(old_screen, new_screen)
  end

  describe '#update' do
    it 'is not done after a single tic' do
      melt = build_melt(1234)
      fb = Array.new(SIZE, -1)
      expect(melt.update(fb)).to be false
      expect(melt.done?).to be false
    end

    it 'writes every pixel from one of the two source screens' do
      melt = build_melt(1234)
      fb = Array.new(SIZE, -1)
      melt.update(fb)
      # No pixel left untouched (-1), and each is either old (0) or new (1).
      expect(fb).to all(satisfy { |px| [0, 1].include?(px) })
    end

    it 'is deterministic for a given rand seed' do
      fb1 = Array.new(SIZE, -1)
      build_melt(4242).update(fb1)

      fb2 = Array.new(SIZE, -1)
      build_melt(4242).update(fb2)

      expect(fb1).to eq(fb2)
    end

    it 'diverges for different rand seeds once melting is underway' do
      # The first tic shows mostly the old screen for any seed (columns start
      # with a negative delay), so advance until the jagged melt line shows.
      fb1 = Array.new(SIZE, -1)
      m1 = build_melt(1)
      10.times { m1.update(fb1) }

      fb2 = Array.new(SIZE, -1)
      m2 = build_melt(999_999)
      10.times { m2.update(fb2) }

      expect(fb1).not_to eq(fb2)
    end

    it 'eventually completes and shows only the new screen' do
      melt = build_melt(1234)
      fb = Array.new(SIZE, -1)

      done = false
      300.times do
        done = melt.update(fb)
        break if done
      end

      expect(done).to be true
      expect(melt.done?).to be true
      expect(fb).to eq(new_screen)
    end
  end
end
