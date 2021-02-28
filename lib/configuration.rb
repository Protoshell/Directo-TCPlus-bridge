# frozen_string_literal: true

require 'yaml'
require_relative 'logging'

# Configuration loader
class Configuration
  include Logging

  def initialize(config_file = 'config.yml')
    logger.info "Loading config from #{config_file}"
    @config = YAML.load_file(config_file)
  end

  def config(name)
    @config[name]
  end
end
