# frozen_string_literal: true

# Report Service
# Generates reports and CSV exports for orders

require 'csv'

module CoffeeBot
  module Services
    class ReportService
      # Generate CSV report for orders
      #
      # @param start_date [Time, Date, nil] Start date filter
      # @param end_date [Time, Date, nil] End date filter
      # @param status [String, nil] Status filter
      # @return [String] CSV content
      def self.generate_orders_csv(start_date: nil, end_date: nil, status: nil)
        query = Order.order(:created_at)
        
        if start_date
          query = query.where(Sequel.lit('created_at >= ?', start_date.to_time.utc))
        end
        
        if end_date
          query = query.where(Sequel.lit('created_at <= ?', end_date.to_time.utc))
        end
        
        if status
          query = query.where(status: status)
        end
        
        orders = query.all
        
        CSV.generate(headers: true) do |csv|
          csv << [
            'ID',
            'Номер счета',
            'Telegram ID',
            'Клиент',
            'Статус',
            'Сумма (соты)',
            'Валюта',
            'Комментарий',
            'Создан',
            'Обновлен',
            'Оплачен',
            'Состав заказа'
          ]
          
          orders.each do |order|
            csv << [
              order.id,
              order.merchant_invoice_id,
              order.telegram_user_id,
              order.client_display_name,
              order.status,
              order.total_amount,
              order.currency,
              order.comment,
              order.created_at&.strftime('%Y-%m-%d %H:%M:%S'),
              order.updated_at&.strftime('%Y-%m-%d %H:%M:%S'),
              order.paid_at&.strftime('%Y-%m-%d %H:%M:%S'),
              format_order_items(order)
            ]
          end
        end
      end

      # Generate daily sales report
      #
      # @param date [Date] Date to generate report for
      # @return [Hash] Report data
      def self.daily_sales_report(date = Date.today)
        start_time = date.to_time.utc
        end_time = start_time + 86400 # 1 day
        
        orders = Order.where(
          status: [OrderStatus::PAID, OrderStatus::READY, OrderStatus::COMPLETED],
          created_at: (start_time..end_time)
        ).all
        
        total_amount = orders.sum(&:total_amount)
        orders_count = orders.length
        
        # Group by hour
        by_hour = orders.group_by { |o| o.created_at.hour }
        hourly_data = (0..23).map do |hour|
          {
            hour: hour,
            count: by_hour[hour]&.length || 0,
            amount: by_hour[hour]&.sum(&:total_amount) || 0
          }
        end
        
        # Top items
        top_items = calculate_top_items(orders)
        
        {
          date: date.to_s,
          orders_count: orders_count,
          total_amount: total_amount,
          total_amount_formatted: format_amount(total_amount),
          hourly_data: hourly_data,
          top_items: top_items
        }
      end

      # Generate sales report for period
      #
      # @param start_date [Date] Start date
      # @param end_date [Date] End date
      # @return [Hash] Report data
      def self.period_sales_report(start_date, end_date)
        start_time = start_date.to_time.utc
        end_time = end_date.to_time.utc + 86400 # Include end date
        
        orders = Order.where(
          status: [OrderStatus::PAID, OrderStatus::READY, OrderStatus::COMPLETED],
          created_at: (start_time..end_time)
        ).all
        
        total_amount = orders.sum(&:total_amount)
        orders_count = orders.length
        
        # Group by day
        by_day = orders.group_by { |o| o.created_at.to_date }
        
        daily_data = (start_date..end_date).map do |date|
          day_orders = by_day[date] || []
          {
            date: date.to_s,
            count: day_orders.length,
            amount: day_orders.sum(&:total_amount)
          }
        end
        
        # Top items
        top_items = calculate_top_items(orders)
        
        # Unique clients
        unique_clients = orders.map(&:telegram_user_id).uniq.length
        
        {
          start_date: start_date.to_s,
          end_date: end_date.to_s,
          orders_count: orders_count,
          total_amount: total_amount,
          total_amount_formatted: format_amount(total_amount),
          unique_clients: unique_clients,
          average_order: orders_count > 0 ? format_amount(total_amount / orders_count) : '0',
          daily_data: daily_data,
          top_items: top_items
        }
      end

      private

      # Format order items for CSV
      def self.format_order_items(order)
        order.order_items.map do |item|
          "#{item.item_name} x#{item.qty}"
        end.join('; ')
      end

      # Calculate top items from orders
      def self.calculate_top_items(orders)
        item_counts = Hash.new(0)
        item_amounts = Hash.new(0)
        
        orders.each do |order|
          order.order_items.each do |item|
            item_counts[item.item_name] += item.qty
            item_amounts[item.item_name] += item.line_total
          end
        end
        
        item_counts.sort_by { |_, count| -count }.first(10).map do |name, count|
          {
            name: name,
            count: count,
            amount: item_amounts[name],
            amount_formatted: format_amount(item_amounts[name])
          }
        end
      end

      # Format amount in soms
      def self.format_amount(soms)
        return '0' if soms.nil? || soms.zero?
        "#{som / 100} сом"
      end
    end
  end
end
