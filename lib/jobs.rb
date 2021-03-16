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
    logger.info 'Getting new warehouse transfers'
    response = @erp_client.transfers(
      {
        'tostock' => @config.config('WarehouseLocation'),
        'status' => @config.config('OrderStatuses')['New']
      }
    )
    parse_response_transfers(response)
  rescue Errno::ETIMEDOUT => e
    logger.error e.message
  rescue DirectoTransportError => e
    logger.error "Error getting warehouse transfers.\n #{e.full_message}"
  end

  def parse_return_files
    Dir["#{@config.config('Directories')['Results']}/*"].each do |filename|
      logger.info "Parsing return file #{filename}"
      xml_doc = Nokogiri::XML(read_file_contents(filename))
      case xml_doc.css('Tcplus').first.elements.first.name
      when 'InventoryReturn'
        logger.debug 'Return type: Inventory'
        logger.error 'Inventory update not yet supported.'
      when 'PurchaseReturn'
        parse_purchase_return(xml_doc)
      when 'PickReturn'
        parse_pick_return(xml_doc)
      else
        logger.warn 'Unknown return type'
      end
    end
  end

  private

  def handle_delivery_rows(delivery, xml, rows)
    delivery.css('rows row').each do |row|
      next unless row['qty'].to_i.positive?

      rows += 1
      xml.Line do
        xml.ArticleNumber row['item']
        xml.OrderedQty row['qty']
        xml.Description row['name']
        xml.Picklineinfo row['comment']
        xml.LineNumber row['rn']
      end
    end
    [xml, rows]
  end

  def handle_delivery(delivery)
    rows = 0

    output = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      xml.OrderData do
        xml.Order do
          xml.OrderNumber delivery['number']
          xml.CustomerNumber delivery['customercode']
          xml.CustomerName delivery['customername']
          xml.OrderDate Time.parse(delivery['date']).strftime('%Y-%m-%d')
        end
        xml, rows = handle_delivery_rows(delivery, xml, rows)
      end
    end
    [output.to_xml, rows]
  end

  def parse_response_deliveries(deliveries)
    return if deliveries.count.zero?

    logger.info "Handling #{deliveries.count} delivery orders"

    deliveries.each do |delivery|
      output, rows = handle_delivery(delivery)

      if rows.zero?
        logger.debug "Skipping delivery #{delivery['number']} because no valid lines"
        @erp_client.update_delivery_status(delivery['number'], @config.config('OrderStatuses')['ReadyFromTcplus'])
        next
      end

      write_file_contents("#{@config.config('Directories')['Orders']}/order_#{delivery['number']}.xml", output)
      @erp_client.update_delivery_status(delivery['number'], @config.config('OrderStatuses')['MovedToTcplus'])
    rescue StandardError => e
      logger.error "Unable to handle delivery\n#{delivery.inspect}\n#{e.full_message}"
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
            xml.LineNumber row['rn']
          end
        end
      end
    end.to_xml
  end

  def parse_response_transfers(transfers)
    logger.info "Handling #{transfers.count} transfer orders" unless transfers.count.zero?

    transfers.each do |transfer|
      logger.info "Handling #{transfer['number']}"
      output = handle_transfer(transfer)

      write_file_contents("#{@config.config('Directories')['PurchaseOrders']}/purchase_#{transfer['number']}.xml", output)
      @erp_client.update_transfer_status(transfer['number'], @config.config('OrderStatuses')['MovedToTcplus'])
    rescue StandardError => e
      logger.error "Unable to parse delivery\n#{transfer.inspect}\n#{e}\n#{e.backtrace}"
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
    data
  end

  def parse_purchase_return(xml_doc)
    logger.debug 'Return type: PurchaseReturn'

    transfers = {}
    xml_doc.css('Tcplus PurchaseReturn Data').each do |data|
      ordernumber = data.at_css('OrderNumber').content
      transfers[ordernumber] = @erp_client.transfer_by_number(ordernumber) unless transfers[ordernumber]
      transfers[ordernumber].at_xpath("//row[@item='#{data.at_css('ArticleNumber').content}']")['movedqty'] = data.at_css('Delivered').content
      # TODO: SerialNumber?
    end
    transfers.each_value do |transfer|
      transfer['status'] = @config.config('OrderStatuses')['ReadyFromTcplus']
      logger.debug transfer.to_xml
      @erp_client.update_transfer(transfer)
    end
  end

  def parse_pick_return(xml_doc)
    logger.debug 'Return type: PickReturn'

    deliveries = {}
    xml_doc.css('Tcplus PickReturn Data').each do |data|
      ordernumber = data.at_css('OrderNumber').content
      logger.debug ordernumber
      deliveries[ordernumber] = @erp_client.delivery_by_number(ordernumber) unless deliveries[ordernumber]
      deliveries[ordernumber].at_xpath("//row[@item='#{data.at_css('ArticleNumber').content}']")['movedqty'] = data.at_css('Delivered').content
      # TODO: SerialNumber?
    end
    deliveries.each_value do |delivery|
      delivery['status'] = @config.config('OrderStatuses')['ReadyFromTcplus']
      logger.debug delivery.to_xml
      @erp_client.update_delivery(delivery)
    end
  end
end
