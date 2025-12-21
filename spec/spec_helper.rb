# frozen_string_literal: true

# Load core modules without platform-specific code (Gosu)
require_relative '../lib/doom/version'
require_relative '../lib/doom/wad/reader'
require_relative '../lib/doom/wad/palette'
require_relative '../lib/doom/wad/colormap'
require_relative '../lib/doom/wad/flat'
require_relative '../lib/doom/wad/patch'
require_relative '../lib/doom/wad/texture'
require_relative '../lib/doom/wad/sprite'
require_relative '../lib/doom/map/data'
require_relative '../lib/doom/render/renderer'

module Doom
  class Error < StandardError; end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!
  config.warnings = true

  config.order = :random
  Kernel.srand config.seed
end

# Helper to get path to test WAD
def wad_path
  File.join(__dir__, '..', 'doom1.wad')
end

# Skip tests if WAD file not present
def skip_without_wad
  skip 'doom1.wad not found' unless File.exist?(wad_path)
end
