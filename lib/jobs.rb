# frozen_string_literal: true

require_relative 'configuration'
require_relative 'directo_client'
require_relative 'logging'

# Business logic jobs
class Jobs
  include Logging

  def initialize
    @config = Configuration.new
    @last_item_sync = nil
    @erp_client = if @config.config('DirectoAPI').nil?
                    DirectoClient.new
                  else
                    DirectoClient.new(
                      @config.config('DirectoAPI')['Organization'],
                      @config.config('DirectoAPI')['APIKey']
                    )
                  end
  end

  def synchronize_items
    hours_from_history = if @config.config('SynchronizeItemHistoryHours').nil?
                           6
                         else
                           @config.config('SynchronizeItemHistoryHours')
                         end

    if File.exist?("#{@config.config('Directories')['Items']}/items.xml")
      logger.debug 'Previous items file exists. Skipping update.'
      return
    end

    sync_time = DateTime.now
    items = if @last_item_sync.nil?
              @erp_client.items
            else
              @erp_client.items_by_timestamp((@last_item_sync - (hours_from_history / 24.0)).strftime('%d.%m.%Y %H:%M'))
            end
    write_file_contents("#{@config.config('Directories')['Items']}/items.xml", items_to_xml(parse_response_items(items)))

    @last_item_sync = sync_time
  end

  def synchronize_deliveries
    logger.info 'Getting new deliveries'
    response = @erp_client.deliveries(
      {
        'stock' => @config.config('WarehouseLocation'),
        'status' => @config.config('OrderStatuses')['New']
      }
    )
    parse_response_deliveries(response)
  end

  def synchronize_transfers
    logger.info 'Getting new warehouse transfers in'
    response = @erp_client.transfers(
      {
        'tostock' => @config.config('WarehouseLocation'),
        'status' => @config.config('OrderStatuses')['New']
      }
    )
    parse_response_transfers(response, 'in')
  rescue Errno::ETIMEDOUT => e
    logger.error e.message
  rescue DirectoTransportError => e
    logger.error "Error getting warehouse transfers.\n #{e.full_message}"
  end

  def synchronize_transfers_out
    logger.info 'Getting new warehouse transfers out'
    response = @erp_client.transfers(
      {
        'fromstock' => @config.config('WarehouseLocation'),
        'status' => @config.config('OrderStatuses')['New']
      }
    )
    parse_response_transfers(response, 'out')
  rescue Errno::ETIMEDOUT => e
    logger.error e.message
  rescue DirectoTransportError => e
    logger.error "Error getting warehouse transfers.\n #{e.full_message}"
  end

  def parse_return_files
    return_filenames.each do |filename|
      handle_return_file(filename)
    rescue UnknownOrderError => e
      logger.error "Unrecoverable error updating Directo.\n#{e.full_message}"
      File.delete(filename)
    rescue DirectoCommitError => e
      logger.error "Unrecoverable error updating Directo.\n#{e.full_message}"
      File.delete(filename)
    end
  rescue DirectoTransportError => e
    logger.error "Error updating Directo.\n#{e.full_message}"
  end

  private

  def handle_return_file(filename)
    logger.info "Parsing return file #{filename}"
    xml_doc = Nokogiri::XML(read_file_contents(filename))
    document_type = xml_doc.css('Tcplus').first.elements.first.name
    case document_type
    when 'InventoryReturn'
      logger.debug 'Return type: Inventory'
      logger.error 'Inventory update not yet supported.'
    when 'PurchaseReturn', 'PickReturn'
      xml_doc, type = strip_prefix_from_number(xml_doc)
      parse_return_document(xml_doc, document_type, type)
    else
      logger.warn 'Unknown return type'
      return
    end
    File.delete(filename)
  end

  def return_filenames
    logger.debug 'Searching for return files'
    files = Dir["#{@config.config('Directories')['Results']}/*"]
    logger.debug "Found #{files.count} files"
    files
  end

  def prefix_number_with_type(document, prefix)
    document['number'] = "#{prefix}#{document['number']}"
    document
  end

  def strip_prefix_from_number(document)
    document_type = document.css('Tcplus').first.elements.first.name
    type = nil
    document.css("Tcplus #{document_type} Data").each do |node|
      captures = node.at_css('OrderNumber').content.match(/([A-Z]*)(\d+)/).captures
      type = captures[0]
      node.at_css('OrderNumber').content = captures[1]
    end
    [document, type]
  end

  def handle_delivery_rows(delivery, xml, rows)
    delivery.css('rows row').each do |row|
      next unless row['qty'].to_i.positive?

      rows += 1
      xml.Line do
        xml.ArticleNumber row['item']
        xml.OrderedQty row['qty']
        xml.Description row['name']
        xml.Picklineinfo row['comment']
        xml.BatchNumber row['sn'] unless row['sn'].nil? || row['sn'].empty?
        xml.LineNumber row['rn']
      end
    end
    [xml, rows]
  end

  def value_or_default(value, default)
    if value.nil?
      default
    else
      value
    end
  end

  def handle_delivery(delivery)
    rows = 0

    raise ArgumentError 'Document already confirmed. Updating not possible!' if delivery['confirmed'] == '1'

    customernumber = value_or_default(delivery['customercode'], '-')
    customername = value_or_default(delivery['customername'], 'Warehouse transfer')

    output = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.OrderData do
        xml.Order do
          xml.OrderNumber delivery['number']
          xml.CustomerNumber customernumber
          xml.CustomerName customername
          xml.OrderDate Time.parse(delivery['date']).strftime('%Y-%m-%d')
        end
        xml, rows = handle_delivery_rows(delivery, xml, rows)
      end
    end
    [output.to_xml, rows]
  end

  def skip_delivery(delivery_number)
    logger.debug "Skipping delivery #{delivery_number} because no valid lines"
    @erp_client.update_delivery_status(delivery_number, @config.config('OrderStatuses')['ReadyFromTcplus'])
  end

  def parse_response_deliveries(deliveries)
    return if deliveries.count.zero?

    logger.info "Handling #{deliveries.count} delivery orders"

    deliveries.each do |delivery|
      erp_document_number = delivery['number']
      output, rows = handle_delivery(prefix_number_with_type(delivery, 'D'))

      if rows.zero?
        skip_delivery(erp_document_number)
        next
      end

      write_file_contents("#{@config.config('Directories')['Orders']}/order_#{delivery['number']}.xml", output)
      @erp_client.update_delivery_status(erp_document_number, @config.config('OrderStatuses')['MovedToTcplus'])
    rescue StandardError => e
      logger.error "Unable to handle delivery\n#{delivery}\n#{e.full_message}"
    end
  end

  def handle_transfer(transfer)
    Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.PurchaseOrderData do
        xml.Order do
          xml.OrderNumber transfer['number']
          xml.OrderDate Time.parse(transfer['date']).strftime('%Y-%m-%d')
        end
        transfer.css('rows row').each do |row|
          xml.Line do
            xml.ArticleNumber row['item']
            xml.OrderedQty row['qty']
            xml.Description row['name']
            xml.Picklineinfo row['comment']
            xml.BatchNumber row['sn'] unless row['sn'].empty?
            xml.LineNumber row['rn']
          end
        end
      end
    end.to_xml
  end

  def parse_response_transfers(transfers, direction)
    logger.info "Handling #{transfers.count} transfer orders" unless transfers.count.zero?

    transfers.each do |transfer|
      transfer_number_erp = transfer['number']
      logger.info "Handling #{transfer_number_erp}"
      transfer = prefix_number_with_type(transfer, 'T')
      raise ArgumentError 'Document already confirmed. Updating not possible!' if transfer['confirmed'] == '1'

      # TODO: Parse direction from content?
      write_transfer_output_file(transfer, direction)
      @erp_client.update_transfer_status(transfer_number_erp, @config.config('OrderStatuses')['MovedToTcplus'])
    rescue StandardError => e
      logger.error "Unable to parse delivery\n#{transfer.inspect}\n#{e}\n#{e.backtrace}"
    end
  end

  def write_transfer_output_file(transfer, direction)
    case direction
    when 'in'
      output = handle_transfer(transfer)

      write_file_contents("#{@config.config('Directories')['PurchaseOrders']}/purchase_#{transfer['number']}.xml", output)
    when 'out'
      output, rows = handle_delivery(transfer)

      write_file_contents("#{@config.config('Directories')['Orders']}/order_#{transfer['number']}.xml", output) if rows.positive?
    end
  end

  def zero_to_nil(value)
    if value.zero?
      nil
    else
      value
    end
  end

  def parse_response_items(nokogiri_items)
    items = []

    nokogiri_items.each do |item|
      # Skip products that are not stock items (services etc.)
      next if item.attributes['type'].value != '1'

      items << {
        code: item.attributes['code'].value,
        name: item['name'],
        # sntype: 0 = no tracking, 1 = batch tracking, 2 = serial number tracking
        serialnumber: item.attributes['sntype']&.value.to_i,
        weight: zero_to_nil(item.attributes['weight']&.value.to_f)
      }
    rescue StandardError => e
      logger.error "Unable to parse item\n#{item.inspect}\n#{e}\n#{e.backtrace}"
    end

    logger.info "Found #{items.count} items"

    items
  end

  def directo_serial_number_required?(value)
    if value == 1
      1
    else
      0
    end
  end

  def directo_batch_number_required?(value)
    if value == 2
      1
    else
      0
    end
  end

  def kilograms_to_grams(kilograms)
    (kilograms * 1000).round(3)
  end

  def items_to_xml(items)
    Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.root do
        items.each do |item|
          xml.ItemData do
            xml.ItemCode item[:code]
            xml.ItemDescription item[:name]
            xml.WeightG kilograms_to_grams(item[:weight]) if item[:weight]
            xml.RequireSerialNumber directo_serial_number_required?(item[:serialnumber])
            xml.RequireBatchNumber directo_batch_number_required?(item[:serialnumber])
          end
        end
      end
    end.to_xml
  end

  def write_file_contents(filename, contents)
    File.open(filename, 'w') do |file|
      file.write(contents)
    end
  end

  def read_file_contents(filename)
    file = File.open(filename)
    data = file.read
    file.close
    logger.debug "Read content: '#{data}'"
    data
  end

  def parse_return_document(xml_doc, document_type, real_type)
    logger.debug "Return type: #{document_type}"

    documents = {}
    xml_doc.css("Tcplus #{document_type} Data").each do |data|
      ordernumber = data.at_css('OrderNumber').content
      unless documents[ordernumber]
        documents[ordernumber] = case real_type
                                 when 'T'
                                   @erp_client.transfer_by_number(ordernumber)
                                 when 'D'
                                   @erp_client.delivery_by_number(ordernumber)
                                 when 'MP'
                                   logger.error 'Manual pick not supported. Skipping...'
                                   next
                                 when 'MS'
                                   logger.error 'Manual supply not supported. Skipping...'
                                   next
                                 else
                                   raise ArgumentError, "Unknown order type #{real_type}"
                                 end
        documents[ordernumber].xpath('//row').each do |row|
          row['movedqty'] = 0
        end
      end
      orderline = documents[ordernumber].at_xpath("//row[@rn='#{data.at_css('LineNumber').content}']")
      raise ArgumentError 'Order line not found' unless orderline

      orderline['movedqty'] =
        (orderline['movedqty'].to_i + data.at_css('Delivered').content.to_i)
      orderline['sn'] = data.at_css('LocationInfo').content unless data.at_css('LocationInfo').content.empty?
    end
    documents.each_value do |document|
      document['status'] = @config.config('OrderStatuses')['ReadyFromTcplus']
      logger.debug document.to_xml
      case real_type
      when 'T'
        @erp_client.update_transfer(document)
      when 'D'
        @erp_client.update_delivery(document)
      end
    end
  end
end
