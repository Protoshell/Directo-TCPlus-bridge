# frozen_string_literal: true

require_relative 'lib/jobs'
require 'rufus-scheduler'

scheduler = Rufus::Scheduler.new

jobs = Jobs.new

scheduler.interval('1m') do
  jobs.synchronize_deliveries
  jobs.synchronize_transfers
  jobs.parse_return_files
end

scheduler.cron '5 0 * * *' do
  jobs.synchronize_all_items
end

scheduler.join

# TODO: Warehouse transfers out?
# TODO: Inventory update
