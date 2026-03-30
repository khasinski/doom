# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

module Doom
  module Wad
    # Plays DOOM music by converting MUS to WAV using a built-in FM synthesizer.
    # No external MIDI tools needed.
    class MusicManager
      # MUS playback rate
      TICKS_PER_SECOND = 140
      SAMPLE_RATE = 22050
      TWO_PI = 2.0 * Math::PI
      MAX_VOICES = 32
      MASTER_VOLUME = 0.35

      # Map name to WAD lump
      MAP_MUSIC = {
        'E1M1' => 'D_E1M1', 'E1M2' => 'D_E1M2', 'E1M3' => 'D_E1M3',
        'E1M4' => 'D_E1M4', 'E1M5' => 'D_E1M5', 'E1M6' => 'D_E1M6',
        'E1M7' => 'D_E1M7', 'E1M8' => 'D_E1M8', 'E1M9' => 'D_E1M9',
      }.freeze

      TITLE_MUSIC = 'D_INTRO'

      # MUS event types
      MUS_RELEASE = 0; MUS_PLAY = 1; MUS_PITCH = 2
      MUS_SYSTEM = 3; MUS_CONTROLLER = 4; MUS_END = 6

      # MUS controller -> MIDI controller
      CTRL_MAP = { 1 => 0, 2 => 1, 3 => 7, 4 => 10, 5 => 11, 6 => 91, 7 => 93, 8 => 64, 9 => 67 }.freeze

      # Simplified FM patch definitions (algo, ratio, mod_idx, attack, decay, sustain, release)
      PATCHES = {
        0  => [2.0, 0.005, 0.8, 0.0, 0.3],   # Piano
        16 => [0.3, 0.02, 0.1, 0.9, 0.1],     # Organ
        24 => [1.2, 0.005, 0.4, 0.2, 0.15],   # Guitar
        29 => [4.0, 0.005, 0.3, 0.7, 0.15],   # Distortion guitar (DOOM staple)
        30 => [5.0, 0.005, 0.2, 0.8, 0.1],    # Overdrive
        32 => [1.5, 0.005, 0.3, 0.4, 0.1],    # Bass
        33 => [2.0, 0.005, 0.25, 0.3, 0.1],   # Finger bass
        34 => [1.0, 0.005, 0.3, 0.3, 0.1],    # Pick bass
        35 => [3.0, 0.005, 0.2, 0.5, 0.1],    # Slap bass
        48 => [0.3, 0.08, 0.2, 0.7, 0.3],     # Strings
        56 => [2.0, 0.03, 0.15, 0.8, 0.1],    # Brass
        80 => [0.0, 0.01, 0.1, 0.8, 0.1],     # Square lead
      }.freeze
      DEFAULT_PATCH = [1.0, 0.01, 0.2, 0.6, 0.15]

      # Percussion
      PERC = {
        35 => [55, 0.3, 8.0, 0.5],   36 => [60, 0.25, 10.0, 0.5],
        38 => [200, 0.15, 12.0, 2.3], 40 => [200, 0.12, 15.0, 2.3],
        42 => [800, 0.05, 6.0, 7.1],  46 => [700, 0.15, 5.0, 7.1],
        49 => [400, 0.4, 4.0, 5.3],   51 => [500, 0.3, 3.0, 5.3],
        41 => [100, 0.2, 6.0, 1.5],   45 => [150, 0.18, 5.0, 1.5],
        47 => [180, 0.15, 5.0, 1.5],
      }.freeze

      def initialize(wad)
        @wad = wad
        @temp_dir = File.join(Dir.tmpdir, "doom_rb_music_#{Process.pid}")
        FileUtils.mkdir_p(@temp_dir)
        @cache = {}
        @current_song = nil
        @render_thread = nil
      end

      def play_map(map_name)
        lump_name = MAP_MUSIC[map_name.upcase]
        play_lump(lump_name) if lump_name
      end

      def play_title
        play_lump(TITLE_MUSIC)
      end

      def stop
        @current_song&.stop
        @current_song = nil
      end

      def playing?
        @current_song&.playing? || false
      end

      private

      def play_lump(name)
        # Render in background thread to avoid blocking game startup
        @render_thread&.kill if @render_thread&.alive?
        @render_thread = Thread.new do
          wav_path = render_mus_to_wav(name)
          if wav_path
            @current_song&.stop
            @current_song = Gosu::Song.new(wav_path)
            @current_song.play(true)
          end
        rescue => e
          # Silently fail
        end
      end

      def render_mus_to_wav(lump_name)
        return @cache[lump_name] if @cache[lump_name]

        data = @wad.read_lump(lump_name)
        return nil unless data && data.size > 14 && data[0, 4] == "MUS\x1a"

        events = parse_mus(data)
        return nil if events.empty?

        wav_path = File.join(@temp_dir, "#{lump_name}.wav")
        wav_data = render_to_wav(events)
        File.binwrite(wav_path, wav_data)
        @cache[lump_name] = wav_path
        wav_path
      end

      def parse_mus(data)
        score_start = data[6, 2].unpack1('v')
        pos = score_start
        tick = 0
        events = []
        channel_vel = Array.new(16, 100)

        while pos < data.size
          byte = data.getbyte(pos); pos += 1
          break unless byte

          last = (byte & 0x80) != 0
          etype = (byte >> 4) & 0x07
          mus_ch = byte & 0x0F
          midi_ch = mus_ch == 15 ? 9 : (mus_ch < 9 ? mus_ch : mus_ch + 1)

          case etype
          when MUS_RELEASE
            note = data.getbyte(pos) & 0x7F; pos += 1
            events << [tick, :off, midi_ch, note, 0]
          when MUS_PLAY
            nb = data.getbyte(pos); pos += 1
            note = nb & 0x7F
            if (nb & 0x80) != 0
              channel_vel[mus_ch] = data.getbyte(pos) & 0x7F; pos += 1
            end
            events << [tick, :on, midi_ch, note, channel_vel[mus_ch]]
          when MUS_PITCH
            bend = data.getbyte(pos); pos += 1
            events << [tick, :bend, midi_ch, bend, 0]
          when MUS_SYSTEM
            pos += 1
          when MUS_CONTROLLER
            cn = data.getbyte(pos) & 0x7F; cv = data.getbyte(pos + 1) & 0x7F; pos += 2
            if cn == 0
              events << [tick, :prog, midi_ch, cv, 0]
            end
          when MUS_END
            break
          end

          if last
            delay = 0
            loop do
              db = data.getbyte(pos); pos += 1
              break unless db
              delay = (delay << 7) | (db & 0x7F)
              break if (db & 0x80) == 0
            end
            tick += delay
          end
        end
        events
      end

      def render_to_wav(events)
        last_tick = events.last[0]
        total_seconds = last_tick.to_f / TICKS_PER_SECOND + 2.0
        total_samples = (total_seconds * SAMPLE_RATE).to_i
        dt = 1.0 / SAMPLE_RATE
        spt = SAMPLE_RATE.to_f / TICKS_PER_SECOND

        voices = []
        programs = Array.new(16, 0)
        pcm = Array.new(total_samples, 0.0)
        eidx = 0

        total_samples.times do |i|
          ctick = i.to_f / spt
          while eidx < events.size && events[eidx][0] <= ctick
            e = events[eidx]; eidx += 1
            case e[1]
            when :on
              if e[2] == 9
                p = PERC[e[3]]
                voices << make_perc_voice(p, e[4]) if p
              else
                patch = PATCHES[programs[e[2]]] || DEFAULT_PATCH
                voices << make_voice(e[3], e[4], patch, e[2])
              end
              voices.shift if voices.size > MAX_VOICES
            when :off
              voices.each { |v| v[7] = true if v[0] == e[2] && v[1] == e[3] && !v[8] }
            when :prog
              programs[e[2]] = e[3]
            end
          end

          mix = 0.0
          voices.reject! do |v|
            s = voice_sample(v, dt)
            if s
              mix += s
              false
            else
              true
            end
          end
          pcm[i] = (mix * MASTER_VOLUME).clamp(-1.0, 1.0)
        end

        build_wav(pcm)
      end

      # Voice: [channel, note, freq, velocity, phase_c, phase_m, time, released, done, patch, rel_time, rel_level]
      def make_voice(note, vel, patch, channel)
        freq = 440.0 * (2.0 ** ((note - 69) / 12.0))
        [channel, note, freq, vel / 127.0, 0.0, 0.0, 0.0, false, false,
         patch, 0.0, 0.0]
      end

      def make_perc_voice(p, vel)
        # p = [freq, decay, mod_idx, ratio]
        patch = [p[2], 0.001, p[1], 0.0, 0.01]
        [9, -1, p[0], vel / 127.0, 0.0, 0.0, 0.0, false, false,
         patch, 0.0, 0.0]
      end

      def voice_sample(v, dt)
        return nil if v[8] # done

        # ADSR
        patch = v[9]
        mod_idx, attack, decay, sustain, release = patch
        t = v[6]

        if v[7] # released
          re = t - v[10]
          if re >= release
            v[8] = true
            return nil
          end
          env = v[11] * (1.0 - re / release)
        elsif t < attack
          env = t / attack
        elsif t < attack + decay
          env = 1.0 - (1.0 - sustain) * ((t - attack) / decay)
        else
          env = sustain
        end

        # FM synthesis
        mod = Math.sin(v[5]) * mod_idx * env
        out = Math.sin(v[4] + mod) * env * v[3]

        v[4] += TWO_PI * v[2] * dt
        v[5] += TWO_PI * v[2] * 1.0 * dt  # Ratio 1:1 for simplicity
        v[4] -= TWO_PI if v[4] > TWO_PI
        v[5] -= TWO_PI if v[5] > TWO_PI
        v[6] += dt

        # Auto-release check
        if v[7] && v[10] == 0.0
          v[10] = t
          v[11] = env
        end

        out
      end

      def build_wav(pcm)
        n = pcm.size
        data_size = n * 2
        wav = "RIFF".b
        wav << [36 + data_size].pack('V')
        wav << "WAVEfmt ".b
        wav << [16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16].pack('VvvVVvv')
        wav << "data".b
        wav << [data_size].pack('V')
        pcm.each { |s| wav << [(s.clamp(-1.0, 1.0) * 32767).to_i].pack('s<') }
        wav
      end
    end
  end
end
