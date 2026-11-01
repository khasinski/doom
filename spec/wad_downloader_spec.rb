# frozen_string_literal: true

require 'tmpdir'
require 'spec_helper'
require_relative '../lib/doom/wad_downloader'

RSpec.describe Doom::WadDownloader do
  describe '.download_from_url' do
    it 'uses Ruby standard-library HTTP inside the Doom::Net namespace' do
      response = Net::HTTPOK.new('1.1', '200', 'OK')
      allow(response).to receive(:[]).with('content-length').and_return('3')
      allow(response).to receive(:read_body).and_yield('wad')

      http = double('HTTP connection')
      allow(http).to receive(:request) do |request, &block|
        expect(request).to be_a(Net::HTTP::Get)
        block.call(response)
      end
      allow(Net::HTTP).to receive(:start).and_yield(http)

      Dir.mktmpdir do |directory|
        destination = File.join(directory, 'doom1.wad')
        described_class.download_from_url('http://example.test/doom1.wad', destination)

        expect(File.binread(destination)).to eq('wad')
      end
    end
  end
end
