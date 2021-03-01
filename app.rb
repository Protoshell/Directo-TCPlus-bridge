# frozen_string_literal: true

require_relative 'lib/jobs'
require 'rufus-scheduler'

scheduler = Rufus::Scheduler.new

jobs = Jobs.new

jobs.synchronize_items

scheduler.interval('1m') do
  jobs.synchronize_deliveries
  jobs.synchronize_transfers
  jobs.parse_return_files
end

scheduler.interval('5m') do
  jobs.synchronize_items
end

scheduler.join

# TODO: Warehouse transfers out?
# TODO: Inventory update
