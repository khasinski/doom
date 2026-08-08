# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/doom/game/menu'
require_relative '../../lib/doom/platform/window_logic'

RSpec.describe Doom::Platform::WindowLogic do
  Menu = Doom::Game::Menu

  # A map thing exposing only the flags field the filter reads.
  Thing = Struct.new(:flags)

  describe '.skill_hidden' do
    # bit 0 = skill 1-2, bit 1 = skill 3, bit 2 = skill 4-5, bit 4 = MP-only.
    let(:things) do
      [
        Thing.new(0x0001), # easy-only
        Thing.new(0x0002), # medium-only
        Thing.new(0x0004), # hard-only
        Thing.new(0x0007), # all skills
        Thing.new(0x0010), # multiplayer-only
      ]
    end

    it 'shows easy/medium/hard-flagged things on baby and easy' do
      [Menu::SKILL_BABY, Menu::SKILL_EASY].each do |skill|
        hidden = described_class.skill_hidden(skill, things)
        expect(hidden).to eq(1 => true, 2 => true, 4 => true) # medium, hard, MP hidden
      end
    end

    it 'shows only medium-flagged things on medium' do
      hidden = described_class.skill_hidden(Menu::SKILL_MEDIUM, things)
      expect(hidden).to eq(0 => true, 2 => true, 4 => true) # easy, hard, MP hidden
    end

    it 'shows hard-flagged things on hard and nightmare' do
      [Menu::SKILL_HARD, Menu::SKILL_NIGHTMARE].each do |skill|
        hidden = described_class.skill_hidden(skill, things)
        expect(hidden).to eq(0 => true, 1 => true, 4 => true) # easy, medium, MP hidden
      end
    end

    it 'always hides multiplayer-only things in single player' do
      Menu::SKILL_ITEMS.each do |skill|
        expect(described_class.skill_hidden(skill, things)).to include(4 => true)
      end
    end

    it 'never hides an all-skills thing regardless of difficulty' do
      Menu::SKILL_ITEMS.each do |skill|
        expect(described_class.skill_hidden(skill, things)).not_to include(3)
      end
    end
  end

  describe '.present_due?' do
    # 60 Hz => ~16.67 ms interval, slack 0.85 => due at ~14.17 ms.
    let(:interval) { 1000.0 / 60 }
    let(:slack) { 0.85 }

    it 'is not due before the slack-adjusted interval elapses' do
      expect(described_class.present_due?(10, 0, interval, slack)).to be false
    end

    it 'is due once the slack-adjusted interval has elapsed' do
      expect(described_class.present_due?(15, 0, interval, slack)).to be true
    end

    it 'accounts for the last present timestamp, not absolute time' do
      expect(described_class.present_due?(1015, 1000, interval, slack)).to be true
      expect(described_class.present_due?(1010, 1000, interval, slack)).to be false
    end
  end

  describe '.net_status_lines' do
    Desync = Struct.new(:tic, :sections)

    def lines(**overrides)
      described_class.net_status_lines(**{
        started: true, host: true, waiting: [],
        stalled_seconds: 0.0, stall_threshold: 0.35, desync: nil
      }.merge(overrides))
    end

    it 'is silent during healthy, started play' do
      expect(lines).to be_empty
    end

    it 'shows a stall only once it exceeds the threshold' do
      expect(lines(waiting: [2], stalled_seconds: 0.1)).to be_empty
      expect(lines(waiting: [2], stalled_seconds: 0.5)).to eq(['WAITING FOR PLAYER 2'])
    end

    it 'never warns about a stall while no one is being waited on' do
      expect(lines(waiting: [], stalled_seconds: 10.0)).to be_empty
    end

    it 'prompts the host and clients differently before the session starts' do
      expect(lines(started: false, host: true)).to eq(['WAITING FOR PLAYERS'])
      expect(lines(started: false, host: false)).to eq(['CONNECTING...'])
    end

    it 'reports a desync with its tic and sections' do
      expect(lines(desync: Desync.new(42, %i[players monsters])))
        .to eq(['DESYNC AT TIC 42 (players, monsters)'])
    end

    it 'can stack a pre-start prompt, a stall and a desync' do
      result = lines(started: false, host: false, waiting: [3],
                     stalled_seconds: 1.0, desync: Desync.new(7, [:world]))
      expect(result).to eq([
        'CONNECTING...',
        'WAITING FOR PLAYER 3',
        'DESYNC AT TIC 7 (world)',
      ])
    end
  end
end
