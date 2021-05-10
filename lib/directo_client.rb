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

  def items(query_options = {}, raw = false)
    options = default_get_options('item')
    options[:query] = options[:query].merge(query_options)
    options[:query]['ts'] = '1.1.1970' if options[:query]['code'].nil? && options[:query]['ts'].nil?
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
    xml_doc = Nokogiri::XML(items({ 'code' => code }, true).body)
    xml_doc.at_css('transport item')
  end

  def items_by_timestamp(timestamp)
    logger.debug "Getting changed items since #{timestamp}"
    items({ 'ts' => timestamp })
  end

  def deliveries(query_options, raw = false)
    raise ArgumentError unless query_options['stock'] || query_options['status'] || query_options['number']

    options = default_get_options('delivery')
    options[:query] = options[:query].merge(query_options)
    response = self.class.get("/#{@config[:organization]}/xmlcore.asp", options)
    check_read_error(response)

    logger.debug "Received deliveries: '#{response.body}'"
    if raw
      response
    else
      xml_doc = Nokogiri::XML(response.body)

      xml_doc.css('transport delivery')
    end
  end

  def delivery_by_number(number)
    response = deliveries({ 'number' => number }, true)
    raise UnknownOrderError, "Unable to get delivery: #{number}" if response.parsed_response['transport'].nil?

    xml_doc = Nokogiri::XML(response.body)
    xml_doc.at_css('transport delivery')
  end

  def deliveries_by_warehouse(warehouse)
    deliveries({ 'stock' => warehouse })
  end

  def deliveries_by_status(status)
    deliveries({ 'status' => status })
  end

  def transfers(query_options, raw = false)
    raise ArgumentError unless query_options['tostock'] || query_options['status'] || query_options['number'] || query_options['fromstock']

    options = default_get_options('movement')
    options[:query] = options[:query].merge(query_options)
    response = self.class.get("/#{@config[:organization]}/xmlcore.asp", options)
    check_read_error(response)

    logger.debug "Received transfers: '#{response.body}'"
    if raw
      response
    else
      xml_doc = Nokogiri::XML(response.body)

      xml_doc.css('transport movement')
    end
  end

  def transfers_by_warehouse(warehouse)
    transfers({ 'tostock' => warehouse })
  end

  def transfers_by_status(status)
    transfers({ 'status' => status })
  end

  def transfer_by_number(number)
    response = transfers({ 'number' => number }, true)

    xml_doc = Nokogiri::XML(response.body)
    xml_doc.at_css('transport movement')
  end

  def update_transfer(transfer)
    raise ArgumentError unless transfer

    transfer = convert_input_to_output(add_appkey_to_xml(transfer), 'transfer')

    logger.debug "Updating transfer: '#{transfer}'"
    response = self.class.post(
      "/#{@config[:organization]}/xmlcore.asp",
      build_httparty_options('<?xml version="1.0" encoding="utf-8"?><movements>' + transfer.to_xml + '</movements>', 'movement')
    )
    logger.debug "Response: '#{response}'"
    check_update_error(response)

    response
  end

  def update_delivery(delivery)
    raise ArgumentError unless delivery

    delivery = convert_input_to_output(add_appkey_to_xml(delivery), 'delivery')

    response = self.class.post(
      "/#{@config[:organization]}/xmlcore.asp",
      build_httparty_options('<?xml version="1.0" encoding="utf-8"?><deliveries>' + delivery.to_xml + '</deliveries>', 'delivery')
    )
    logger.debug "Response: '#{response}'"
    check_update_error(response)

    response
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
    logger.debug "Response: '#{response}'"
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
    logger.debug "Response: '#{response}'"
    check_update_error(response)

    response
  end

  private

  def default_get_options(type)
    options = {}
    options[:query] = @auth.dup
    options[:query]['get'] = '1'
    options[:query]['what'] = type
    options
  end

  def check_read_error(response)
    return if response.ok?

    logger.debug "Received unexpected response: #{response.inspect}"
    raise DirectoTransportError, "Unexpected response code: #{response.response.code}"
  end

  def check_update_error(response)
    return if response.ok? && response.parsed_response['results']['Result']['Type'].to_i.zero?

    result_type = nil
    result_description = ''

    begin
      result_type = response.parsed_response['results']['Result']['Type'].to_i
      result_description = response.parsed_response['results']['Result']['Desc']
    rescue StandardError
      result_type = -1
      result_description = 'Unable to parse result error'
    end

    logger.error response.inspect

    raise DirectoCommitError, "Unable to update: #{result_description}" if result_type == 3

    raise DirectoTransportError, "Unable to update: #{result_description}"
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

  def convert_input_to_output(xml, type)
    xml.search('.//row').each do |row|
      # We need to rename fields for the update to Directo
      case type
      when 'transfer'
        row['itemcode'] = row.delete('item') if row['item']
        row['pickedquantity'] = row.delete('movedqty') if row['movedqty']
      when 'delivery'
        row['quantity'] = row.delete('qty') if row['qty']
      end
    end
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

# Error for document committed, update not allowed
class DirectoCommitError < StandardError
  def initialize(msg = 'Error in API request')
    super
  end
end

# Generic API exception
class DirectoTransportError < StandardError
  def initialize(msg = 'Error in API request')
    super
  end
end
