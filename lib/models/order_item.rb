# frozen_string_literal: true

# OrderItem Model
# Individual items within an order
# Prices are snapshotted to preserve historical data

require_relative '../../config/boot'

class OrderItem < Sequel::Model
  many_to_one :order
  many_to_one :menu_item

  # Validations
  def validate
    super
    errors.add(:order_id, 'cannot be nil') if order_id.nil?
    errors.add(:item_name, 'cannot be empty') if item_name.nil? || item_name.empty?
    errors.add(:qty, 'must be positive') if qty.nil? || qty <= 0
    errors.add(:unit_price, 'must be positive') if unit_price.nil? || unit_price <= 0
    errors.add(:line_total, 'must be positive') if line_total.nil? || line_total <= 0
  end

  # Calculate line total
  def calculate_line_total
    self.line_total = qty * unit_price
  end

  # Format for display
  def to_s
    price_kgs = unit_price.to_f / 100
    total_kgs = line_total.to_f / 100
    "#{item_name} x#{qty} @ #{'%.2f' % price_kgs} KGS = #{'%.2f' % total_kgs} KGS"
  end

  # Format short version
  def short_format
    "#{item_name} x#{qty}"
  end
end
