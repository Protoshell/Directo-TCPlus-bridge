# frozen_string_literal: true

require_relative 'lib/jobs'
require 'rufus-scheduler'

STDOUT.sync = true

scheduler = Rufus::Scheduler.new

jobs = Jobs.new

jobs.synchronize_items

scheduler.interval('1m') do
  jobs.synchronize_deliveries
  jobs.synchronize_transfers
  jobs.synchronize_transfers_out
end

scheduler.interval('15s') do
  jobs.parse_return_files
end

scheduler.interval('5m') do
  jobs.synchronize_items
end

scheduler.join

# TODO: Inventory update
# TODO: Reject confirmed new documents
# TODO: Cancel order
