# frozen_string_literal: true

require 'tmpdir'

module Doom
  module Wad
    # Converts DOOM MUS format to standard MIDI and plays via Gosu::Song.
    # MUS format: proprietary DOOM music format, subset of MIDI.
    class MusicManager
      # MUS event types (high nibble of status byte)
      MUS_RELEASE = 0
      MUS_PLAY = 1
      MUS_PITCH = 2
      MUS_SYSTEM = 3
      MUS_CONTROLLER = 4
      MUS_END = 6

      # MUS controller to MIDI controller mapping
      MUS_TO_MIDI_CTRL = {
        0 => 0,    # Patch change (special: becomes MIDI program change)
        1 => 0,    # Bank select
        2 => 1,    # Modulation
        3 => 7,    # Volume
        4 => 10,   # Pan
        5 => 11,   # Expression
        6 => 91,   # Reverb
        7 => 93,   # Chorus
        8 => 64,   # Sustain pedal
        9 => 67,   # Soft pedal
      }.freeze

      # MUS channel 15 = MIDI channel 9 (percussion)
      # Other channels map 0-14 -> 0-8, 10-15
      def self.mus_to_midi_channel(mus_ch)
        return 9 if mus_ch == 15
        mus_ch < 9 ? mus_ch : mus_ch + 1
      end

      # Map name to WAD lump (E1M1 -> D_E1M1)
      MAP_MUSIC = {
        'E1M1' => 'D_E1M1', 'E1M2' => 'D_E1M2', 'E1M3' => 'D_E1M3',
        'E1M4' => 'D_E1M4', 'E1M5' => 'D_E1M5', 'E1M6' => 'D_E1M6',
        'E1M7' => 'D_E1M7', 'E1M8' => 'D_E1M8', 'E1M9' => 'D_E1M9',
      }.freeze

      TITLE_MUSIC = 'D_INTRO'
      INTERMISSION_MUSIC = 'D_INTER'

      def initialize(wad)
        @wad = wad
        @temp_dir = File.join(Dir.tmpdir, "doom_rb_music_#{Process.pid}")
        FileUtils.mkdir_p(@temp_dir)
        @cache = {}
        @current_song = nil
      end

      def play_map(map_name)
        lump_name = MAP_MUSIC[map_name.upcase]
        play_lump(lump_name) if lump_name
      end

      def play_title
        play_lump(TITLE_MUSIC)
      end

      def play_intermission
        play_lump(INTERMISSION_MUSIC)
      end

      def stop
        @current_song&.stop
        @current_song = nil
      end

      def playing?
        @current_song&.playing?
      end

      private

      def play_lump(name)
        midi_path = convert_to_midi(name)
        return unless midi_path

        @current_song&.stop
        @current_song = Gosu::Song.new(midi_path)
        @current_song.play(true)  # Loop
      rescue => e
        # Silently fail if music can't play
      end

      def convert_to_midi(lump_name)
        return @cache[lump_name] if @cache[lump_name]

        data = @wad.read_lump(lump_name)
        return nil unless data && data.size > 14

        # Verify MUS header
        magic = data[0, 4]
        return nil unless magic == "MUS\x1a"

        midi_path = File.join(@temp_dir, "#{lump_name}.mid")
        midi_data = mus_to_midi(data)
        return nil unless midi_data

        File.binwrite(midi_path, midi_data)
        @cache[lump_name] = midi_path
        midi_path
      end

      def mus_to_midi(mus_data)
        # Parse MUS header
        score_len = mus_data[4, 2].unpack1('v')
        score_start = mus_data[6, 2].unpack1('v')
        _channels = mus_data[8, 2].unpack1('v')
        _sec_channels = mus_data[10, 2].unpack1('v')
        num_instruments = mus_data[12, 2].unpack1('v')

        pos = score_start
        return nil if pos >= mus_data.size

        # Convert MUS events to MIDI events
        midi_events = []
        channel_volumes = Array.new(16, 127)
        channel_last_vel = Array.new(16, 127)

        while pos < mus_data.size
          byte = mus_data.getbyte(pos)
          pos += 1
          break unless byte

          last_event = (byte & 0x80) != 0
          event_type = (byte >> 4) & 0x07
          mus_channel = byte & 0x0F
          midi_ch = MusicManager.mus_to_midi_channel(mus_channel)

          case event_type
          when MUS_RELEASE
            note = mus_data.getbyte(pos) & 0x7F
            pos += 1
            midi_events << { delta: 0, data: [0x80 | midi_ch, note, 0] }

          when MUS_PLAY
            note_byte = mus_data.getbyte(pos)
            pos += 1
            note = note_byte & 0x7F
            if (note_byte & 0x80) != 0
              vol = mus_data.getbyte(pos) & 0x7F
              pos += 1
              channel_last_vel[mus_channel] = vol
            end
            midi_events << { delta: 0, data: [0x90 | midi_ch, note, channel_last_vel[mus_channel]] }

          when MUS_PITCH
            bend = mus_data[pos, 2].unpack1('v')
            pos += 2
            # MUS pitch bend is 0-16383, same as MIDI
            midi_events << { delta: 0, data: [0xE0 | midi_ch, bend & 0x7F, (bend >> 7) & 0x7F] }

          when MUS_SYSTEM
            ctrl = mus_data.getbyte(pos) & 0x7F
            pos += 1
            # System events: 10=all sounds off, 11=all notes off, 14=reset
            case ctrl
            when 10
              midi_events << { delta: 0, data: [0xB0 | midi_ch, 120, 0] }
            when 11
              midi_events << { delta: 0, data: [0xB0 | midi_ch, 123, 0] }
            when 14
              midi_events << { delta: 0, data: [0xB0 | midi_ch, 121, 0] }
            end

          when MUS_CONTROLLER
            ctrl_num = mus_data.getbyte(pos) & 0x7F
            ctrl_val = mus_data.getbyte(pos + 1) & 0x7F
            pos += 2

            if ctrl_num == 0
              # Patch change -> MIDI program change
              midi_events << { delta: 0, data: [0xC0 | midi_ch, ctrl_val] }
            else
              midi_ctrl = MUS_TO_MIDI_CTRL[ctrl_num] || ctrl_num
              midi_events << { delta: 0, data: [0xB0 | midi_ch, midi_ctrl, ctrl_val] }
            end

          when MUS_END
            break
          end

          # Read delay if last_event flag is set
          if last_event
            delay = 0
            loop do
              delay_byte = mus_data.getbyte(pos)
              pos += 1
              break unless delay_byte
              delay = (delay << 7) | (delay_byte & 0x7F)
              break if (delay_byte & 0x80) == 0
            end
            # Apply delay to the NEXT event
            midi_events << { delta: delay, data: nil }
          end
        end

        build_midi(midi_events)
      end

      def build_midi(events)
        # Build MIDI track data
        track = "".b

        # Set tempo: 140 BPM (DOOM default) = 428571 microseconds/beat
        track << write_vlq(0)
        track << [0xFF, 0x51, 0x03].pack('CCC')
        track << [428571].pack('N')[1, 3]

        # Write events
        pending_delta = 0
        events.each do |evt|
          if evt[:data].nil?
            pending_delta += evt[:delta]
            next
          end

          total_delta = pending_delta + evt[:delta]
          pending_delta = 0

          track << write_vlq(total_delta)
          track << evt[:data].pack('C*')
        end

        # End of track
        track << write_vlq(0)
        track << [0xFF, 0x2F, 0x00].pack('CCC')

        # Build complete MIDI file
        midi = "MThd".b
        midi << [6].pack('N')           # Header length
        midi << [0].pack('n')           # Format 0 (single track)
        midi << [1].pack('n')           # 1 track
        midi << [70].pack('n')          # 70 ticks per quarter note (DOOM default)

        midi << "MTrk".b
        midi << [track.size].pack('N')
        midi << track

        midi
      end

      def write_vlq(value)
        result = "".b
        buf = value & 0x7F
        value >>= 7
        while value > 0
          buf <<= 8
          buf |= ((value & 0x7F) | 0x80)
          value >>= 7
        end
        loop do
          result << (buf & 0xFF).chr
          break if (buf & 0x80) == 0
          buf >>= 8
        end
        result
      end
    end
  end
end
