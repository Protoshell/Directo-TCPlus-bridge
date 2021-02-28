# frozen_string_literal: true

require 'httparty'
require 'nokogiri'
require_relative 'logging'

# Directo ERP client
class DirectoClient
  include HTTParty
  include Logging

  logger Logging.logger_for('DirectoClient')

  base_uri 'https://login.directo.ee/xmlcore'

  def initialize(organization = ENV['DIRECTO_ORGANIZATION'], key = ENV['DIRECTO_API_KEY'])
    raise ArgumentError, 'Organization not specified' if organization.nil? || organization.empty?
    raise ArgumentError, 'API Key not specified' if key.nil? || key.empty?

    logger.debug "Initializing Directo Client with organization '#{organization}' and key '#{key.slice(0, 4)}...'"
    @auth = { key: key }
    @config = { organization: organization }
  end

  def items(code = nil, timestamp = '1.1.1970', raw = false)
    options = {}
    options[:query] = @auth
    options[:query]['code'] = code unless code.nil?
    options[:query]['get'] = '1'
    options[:query]['what'] = 'item'
    options[:query]['ts'] = timestamp if code.nil?
    response = self.class.get("/#{@config[:organization]}/xmlcore.asp", options)
    check_read_error(response)

    if raw
      response
    else
      xml_doc = Nokogiri::XML(response.body)

      xml_doc.css('transport item')
    end
  end

  def item_by_code(code)
    xml_doc = Nokogiri::XML(items(code, nil, true).body)
    xml_doc.at_css('transport item')
  end

  def items_by_timestamp(timestamp)
    items(nil, timestamp)
  end

  def deliveries(warehouse, status, number, raw = false)
    raise ArgumentError unless warehouse || status || number

    options = {}
    options[:query] = @auth
    options[:query]['get'] = '1'
    options[:query]['what'] = 'delivery'
    options[:query]['number'] = number
    options[:query]['stock'] = warehouse
    options[:query]['status'] = status
    response = self.class.get("/#{@config[:organization]}/xmlcore.asp", options)
    check_read_error(response)

    if raw
      response
    else
      xml_doc = Nokogiri::XML(response.body)

      xml_doc.css('transport delivery')
    end
  end

  def delivery_by_number(number)
    response = deliveries(nil, nil, number, true)
    raise UnknownOrderError, "Unable to get delivery: #{number}" if response.parsed_response['transport'].nil?

    xml_doc = Nokogiri::XML(response.body)
    xml_doc.at_css('transport delivery')
  end

  def deliveries_by_warehouse(warehouse)
    deliveries(warehouse, nil, nil)
  end

  def deliveries_by_status(status)
    deliveries(nil, status, nil)
  end

  def transfers(warehouse, status, number, raw = false)
    raise ArgumentError unless warehouse || status || number

    options = {}
    options[:query] = @auth
    options[:query]['get'] = '1'
    options[:query]['what'] = 'movement'
    options[:query]['number'] = number
    options[:query]['tostock'] = warehouse
    options[:query]['status'] = status
    response = self.class.get("/#{@config[:organization]}/xmlcore.asp", options)
    check_read_error(response)

    if raw
      response
    else
      xml_doc = Nokogiri::XML(response.body)

      xml_doc.css('transport movement')
    end
  end

  def transfers_by_warehouse(warehouse)
    transfers(warehouse, nil, nil)
  end

  def transfers_by_status(status)
    transfers(nil, status, nil)
  end

  def transfer_by_number(number)
    response = transfers(nil, nil, number, true)

    xml_doc = Nokogiri::XML(response.body)
    xml_doc.at_css('transport movement')
  end

  def update_delivery_status(number, status)
    raise ArgumentError unless number && status

    delivery = sanitize_delivery_for_status_update(delivery_by_number(number))
    delivery['status'] = status
    delivery = add_appkey_to_xml(delivery)

    logger.info "Updating delivery #{number} to #{status}"
    response = self.class.post(
      "/#{@config[:organization]}/xmlcore.asp",
      build_httparty_options('<?xml version="1.0" encoding="utf-8"?><deliveries>' + delivery.to_xml + '</deliveries>', 'delivery')
    )
    check_update_error(response)

    response
  end

  def update_transfer_status(number, status)
    raise ArgumentError unless number && status

    transfer = sanitize_transfer_for_status_update(transfer_by_number(number))
    transfer['status'] = status
    transfer = add_appkey_to_xml(transfer)

    logger.info "Updating transfer #{number} status to #{status}"

    response = self.class.post(
      "/#{@config[:organization]}/xmlcore.asp",
      build_httparty_options('<?xml version="1.0" encoding="utf-8"?><movements>' + transfer.to_xml + '</movements>', 'movement')
    )
    check_update_error(response)

    response
  end

  private

  def check_read_error(response)
    return if response.ok?

    logger.debug "Received unexpected response: #{response.inspect}"
    raise DirectoTransportError, "Unexpected response code: #{response.response.code}"
  end

  def check_update_error(response)
    return unless !response.ok? || !response.parsed_response['results']['Result']['Type'].to_i.zero?

    logger.error response.inspect
    raise DirectoTransportError, 'Unable to update delivery'
  end

  def build_httparty_options(xmldata, type)
    {
      body: {
        xmldata: xmldata,
        put: 1,
        what: type
      }
    }
  end

  def add_appkey_to_xml(xml)
    xml['appkey'] = @auth[:key]
    xml
  end

  def sanitize_delivery_for_status_update(delivery)
    # Rows are not needed when updating only status
    delivery.search('.//rows').remove
    # Remove fields we don't want to update
    delivery.delete('date')
    delivery.delete('ts')
    delivery
  end

  def sanitize_transfer_for_status_update(transfer)
    # Rows are not needed when updating only status
    transfer.search('.//rows').remove
    # Remove fields we don't want to update
    transfer.delete('date')
    transfer.delete('ts')
    transfer.delete('user')
    transfer.delete('confirmed')
    transfer.delete('fromstock')
    transfer.delete('tostock')
    transfer.delete('text')
    transfer
  end
end

# Unknown Order Exception
class UnknownOrderError < StandardError
  def initialize(msg = 'Unknown order')
    super
  end
end

# Generic API exception
class DirectoTransportError < StandardError
  def initialize(msg = 'Error in API request')
    super
  end
end
