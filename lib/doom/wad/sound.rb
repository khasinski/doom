# frozen_string_literal: true

require 'tmpdir'

module Doom
  module Wad
    # Loads DOOM sound effects from WAD and converts to WAV for Gosu playback.
    # DOOM sound format: 8-byte header (2 format, 2 sample_rate, 4 num_samples)
    # followed by unsigned 8-bit PCM samples.
    class SoundManager
      def initialize(wad)
        @wad = wad
        @cache = {}  # name => Gosu::Sample
        @temp_dir = File.join(Dir.tmpdir, "doom_rb_sounds_#{Process.pid}")
        Dir.mkdir(@temp_dir) unless Dir.exist?(@temp_dir)
      end

      # Get or load a sound effect. Returns a Gosu::Sample or nil.
      def [](name)
        return @cache[name] if @cache.key?(name)

        lump_name = name.start_with?('DS') ? name : "DS#{name}"
        entry = @wad.find_lump(lump_name)
        return @cache[name] = nil unless entry

        data = @wad.read_lump_at(entry)
        return @cache[name] = nil if data.size < 8

        # Parse DOOM sound header
        _format = data[0, 2].unpack1('v')
        sample_rate = data[2, 2].unpack1('v')
        num_samples = data[4, 4].unpack1('V')

        # PCM data starts at offset 8, skip 16 padding bytes at start and end
        pcm_start = 8 + 16
        pcm_end = 8 + num_samples - 16
        pcm_data = data[pcm_start...pcm_end]
        return @cache[name] = nil unless pcm_data && pcm_data.size > 0

        # Convert to WAV file for Gosu
        wav_path = File.join(@temp_dir, "#{lump_name}.wav")
        write_wav(wav_path, pcm_data, sample_rate) unless File.exist?(wav_path)

        @cache[name] = Gosu::Sample.new(wav_path)
      rescue => e
        @cache[name] = nil
      end

      def cleanup
        FileUtils.rm_rf(@temp_dir) if @temp_dir && Dir.exist?(@temp_dir)
      end

      private

      # Write unsigned 8-bit PCM data as a WAV file
      def write_wav(path, pcm_data, sample_rate)
        num_samples = pcm_data.size
        data_size = num_samples
        file_size = 36 + data_size

        File.open(path, 'wb') do |f|
          # RIFF header
          f.write("RIFF")
          f.write([file_size].pack('V'))
          f.write("WAVE")

          # fmt chunk
          f.write("fmt ")
          f.write([16].pack('V'))          # chunk size
          f.write([1].pack('v'))           # PCM format
          f.write([1].pack('v'))           # mono
          f.write([sample_rate].pack('V')) # sample rate
          f.write([sample_rate].pack('V')) # byte rate (sample_rate * 1 * 1)
          f.write([1].pack('v'))           # block align
          f.write([8].pack('v'))           # bits per sample

          # data chunk
          f.write("data")
          f.write([data_size].pack('V'))
          f.write(pcm_data)
        end
      end
    end
  end
end
