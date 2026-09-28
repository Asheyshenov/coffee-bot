# frozen_string_literal: true

# A line of an order. Name, size and prices are snapshotted at checkout.
class OrderItem < ApplicationRecord
  acts_as_tenant :tenant

  belongs_to :order
  belongs_to :menu_item, optional: true

  validates :item_name, presence: true
  validates :qty, :unit_price, :line_total, numericality: { only_integer: true, greater_than: 0 }

  def short_format = "#{item_name} x#{qty}"
end
