# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'fileutils'

module Doom
  # Downloads the shareware DOOM1.WAD if not present
  class WadDownloader
    # Official Doom shareware WAD (v1.9) - hosted on archive.org
    SHAREWARE_URL = 'https://archive.org/download/DoomsharewareEpisode/doom1.wad'
    SHAREWARE_SIZE = 4_196_020  # Expected size in bytes
    SHAREWARE_FILENAME = 'doom1.wad'

    class DownloadError < StandardError; end

    def self.ensure_wad_available(custom_path = nil)
      # If custom path provided and exists, use it
      return custom_path if custom_path && File.exist?(custom_path)

      # Check current directory for doom1.wad
      local_wad = File.join(Dir.pwd, SHAREWARE_FILENAME)
      return local_wad if File.exist?(local_wad)

      # Check home directory .doom folder
      home_wad = File.join(Dir.home, '.doom', SHAREWARE_FILENAME)
      return home_wad if File.exist?(home_wad)

      # No WAD found - offer to download
      if custom_path
        raise DownloadError, "WAD file not found: #{custom_path}"
      end

      prompt_and_download(home_wad)
    end

    def self.prompt_and_download(destination)
      puts "No DOOM WAD file found."
      puts
      puts "Would you like to download the shareware version of DOOM (4 MB)?"
      puts "This is the free, legally distributable version with Episode 1."
      puts
      print "Download shareware DOOM? [Y/n] "

      response = $stdin.gets&.strip&.downcase
      if response.nil? || response.empty? || response == 'y' || response == 'yes'
        download_shareware(destination)
        destination
      else
        puts
        puts "To play DOOM, you need a WAD file. Options:"
        puts "  1. Run 'doom' again and accept the shareware download"
        puts "  2. Copy your own doom1.wad or doom.wad to the current directory"
        puts "  3. Specify a WAD path: doom /path/to/your.wad"
        exit 1
      end
    end

    def self.download_shareware(destination)
      puts
      puts "Downloading DOOM shareware..."

      # Create directory if needed
      FileUtils.mkdir_p(File.dirname(destination))

      uri = URI.parse(SHAREWARE_URL)
      downloaded = 0

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        request = Net::HTTP::Get.new(uri)

        http.request(request) do |response|
          case response
          when Net::HTTPRedirection
            # Follow redirect
            return download_from_url(response['location'], destination)
          when Net::HTTPSuccess
            total_size = response['content-length']&.to_i || SHAREWARE_SIZE

            File.open(destination, 'wb') do |file|
              response.read_body do |chunk|
                file.write(chunk)
                downloaded += chunk.size
                print_progress(downloaded, total_size)
              end
            end
          else
            raise DownloadError, "Download failed: #{response.code} #{response.message}"
          end
        end
      end

      puts
      puts "Downloaded to: #{destination}"
      puts

      # Verify file size
      actual_size = File.size(destination)
      if actual_size < 1_000_000  # Less than 1MB is suspicious
        File.delete(destination)
        raise DownloadError, "Download appears incomplete (#{actual_size} bytes)"
      end
    end

    def self.download_from_url(url, destination)
      uri = URI.parse(url)
      downloaded = 0

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        request = Net::HTTP::Get.new(uri)

        http.request(request) do |response|
          case response
          when Net::HTTPRedirection
            return download_from_url(response['location'], destination)
          when Net::HTTPSuccess
            total_size = response['content-length']&.to_i || SHAREWARE_SIZE

            File.open(destination, 'wb') do |file|
              response.read_body do |chunk|
                file.write(chunk)
                downloaded += chunk.size
                print_progress(downloaded, total_size)
              end
            end
          else
            raise DownloadError, "Download failed: #{response.code} #{response.message}"
          end
        end
      end
    end

    def self.print_progress(downloaded, total)
      percent = (downloaded.to_f / total * 100).to_i
      bar_width = 40
      filled = (percent * bar_width / 100)
      bar = '=' * filled + '-' * (bar_width - filled)
      mb_downloaded = (downloaded / 1_048_576.0).round(1)
      mb_total = (total / 1_048_576.0).round(1)
      print "\r[#{bar}] #{percent}% (#{mb_downloaded}/#{mb_total} MB)"
    end
  end
end
