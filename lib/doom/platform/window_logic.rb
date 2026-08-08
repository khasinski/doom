# frozen_string_literal: true

module Doom
  module Platform
    # Pure helpers extracted from GosuWindow so they can be tested without a
    # display. GosuWindow subclasses Gosu::Window, which cannot be loaded (let
    # alone instantiated) under RSpec, so any decision logic worth testing lives
    # here as plain functions and GosuWindow just delegates to them.
    module WindowLogic
      # DOOM thing flags: bit 0 = skill 1-2 (baby/easy), bit 1 = skill 3
      # (medium), bit 2 = skill 4-5 (hard/nightmare), bit 4 = multiplayer-only.
      SKILL_FLAG_EASY = 0x0001
      SKILL_FLAG_MEDIUM = 0x0002
      SKILL_FLAG_HARD = 0x0004
      MULTIPLAYER_ONLY_FLAG = 0x0010

      # The flag bit a thing must carry to appear at the given skill.
      # skill uses Game::Menu::SKILL_* values (0-4).
      def self.skill_flag_bit(skill)
        case skill
        when Game::Menu::SKILL_BABY, Game::Menu::SKILL_EASY then SKILL_FLAG_EASY
        when Game::Menu::SKILL_MEDIUM then SKILL_FLAG_MEDIUM
        when Game::Menu::SKILL_HARD, Game::Menu::SKILL_NIGHTMARE then SKILL_FLAG_HARD
        else SKILL_FLAG_EASY | SKILL_FLAG_MEDIUM | SKILL_FLAG_HARD
        end
      end

      # Which things this skill hides. A thing is hidden if it is
      # multiplayer-only, or if it does not carry the flag bit for this skill.
      # Returns { index => true } (matching the world's skill_hidden shape).
      def self.skill_hidden(skill, things)
        flag_bit = skill_flag_bit(skill)
        hidden = {}
        things.each_with_index do |thing, idx|
          if (thing.flags & MULTIPLAYER_ONLY_FLAG) != 0 || (thing.flags & flag_bit) == 0
            hidden[idx] = true
          end
        end
        hidden
      end

      # Frame-presentation cadence. Rendering runs every loop iteration, but we
      # only blit/swap once a refresh interval (minus slack, so we aim slightly
      # before vblank) has elapsed since the last present.
      def self.present_due?(now_ms, last_present_ms, interval_ms, slack)
        (now_ms - last_present_ms) >= (interval_ms * slack)
      end

      # Net status overlay lines. A lockstep stall under the threshold is normal
      # -- every peer briefly waits for the next command between tics -- so it
      # produces nothing; only a stall past the threshold, a session that has
      # not started yet, or a desync is worth interrupting the player for.
      def self.net_status_lines(started:, host:, waiting:, stalled_seconds:,
                                stall_threshold:, desync: nil)
        lines = []
        lines << (host ? 'WAITING FOR PLAYERS' : 'CONNECTING...') unless started
        if waiting.any? && stalled_seconds > stall_threshold
          lines << "WAITING FOR PLAYER #{waiting.join(', ')}"
        end
        if desync
          lines << "DESYNC AT TIC #{desync.tic} (#{Array(desync.sections).join(', ')})"
        end
        lines
      end
    end
  end
end
