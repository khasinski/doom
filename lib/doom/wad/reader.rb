# frozen_string_literal: true

module Doom
  module Wad
    class Reader
      IWAD = 'IWAD'
      PWAD = 'PWAD'

      DirectoryEntry = Struct.new(:offset, :size, :name)

      attr_reader :type, :num_lumps, :directory

      def initialize(path)
        @file = File.open(path, 'rb')
        read_header
        read_directory
      end

      def find_lump(name)
        @directory.find { |entry| entry.name == name.upcase }
      end

      def read_lump(name)
        return @lump_cache[name] if @lump_cache.key?(name)

        entry = find_lump(name)
        return nil unless entry

        @file.seek(entry.offset)
        data = @file.read(entry.size)
        @lump_cache[name] = data
        data
      end

      def read_lump_at(entry)
        @file.seek(entry.offset)
        @file.read(entry.size)
      end

      def lumps_between(start_marker, end_marker)
        start_idx = @directory.index { |e| e.name == start_marker }
        end_idx = @directory.index { |e| e.name == end_marker }
        return [] unless start_idx && end_idx

        @directory[start_idx + 1...end_idx]
      end

      def pwad?
        @type == PWAD
      end

      def iwad?
        @type == IWAD
      end

      # Merge a PWAD on top of this IWAD.
      # PWAD lumps override IWAD lumps with the same name.
      # Map lumps (between map markers) are replaced as a group.
      def merge_pwad(pwad)
        raise Error, "Can only merge a PWAD" unless pwad.pwad?
        @lump_cache.clear

        pwad.directory.each do |pwad_entry|
          # Check if this lump already exists in the IWAD
          existing_idx = @directory.index { |e| e.name == pwad_entry.name }
          if existing_idx
            # Replace it -- but we need to read from the PWAD file
            @directory[existing_idx] = pwad_entry
          else
            # Append new lump
            @directory << pwad_entry
          end
        end

        # Keep the PWAD file open for reading its lumps
        @pwad_files ||= []
        @pwad_files << pwad
        @num_lumps = @directory.size
      end

      # Override read_lump_at to check if entry belongs to a PWAD file
      def read_lump_at(entry)
        # Try PWAD files first (they may own this entry)
        (@pwad_files || []).each do |pwad|
          if pwad.directory.include?(entry)
            return pwad.read_lump_own(entry)
          end
        end
        @file.seek(entry.offset)
        @file.read(entry.size)
      end

      # Read a lump that belongs to this WAD's own file
      def read_lump_own(entry)
        @file.seek(entry.offset)
        @file.read(entry.size)
      end

      def close
        @file.close
        (@pwad_files || []).each(&:close)
      end

      private

      def read_header
        data = @file.read(12)
        @type = data[0, 4]
        @num_lumps = data[4, 4].unpack1('V')
        @directory_offset = data[8, 4].unpack1('V')
        @lump_cache = {}

        unless [@type == IWAD, @type == PWAD].any?
          raise Error, "Invalid WAD type: #{@type}"
        end
      end

      def read_directory
        @file.seek(@directory_offset)
        @directory = @num_lumps.times.map do
          data = @file.read(16)
          DirectoryEntry.new(
            data[0, 4].unpack1('V'),
            data[4, 4].unpack1('V'),
            data[8, 8].delete("\x00").upcase
          )
        end
      end
    end
  end
end
