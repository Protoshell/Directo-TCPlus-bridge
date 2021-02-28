# frozen_string_literal: true

require 'logger'

# Logging utility
module Logging
  def logger
    @logger ||= Logging.logger_for(self.class.name)
  end

  @loggers = {}

  class << self
    def logger_for(classname)
      @loggers[classname] ||= configure_logger_for(classname)
    end

    def configure_logger_for(classname)
      logger = Logger.new(STDOUT)
      logger.progname = classname
      logger
    end
  end
end
