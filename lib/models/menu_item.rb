# frozen_string_literal: true

# MenuItem Model
# Represents a menu item in the coffee shop

require_relative '../../config/boot'

class MenuItem < Sequel::Model
  # Validations
  def validate
    super
    errors.add(:category, 'cannot be empty') if category.nil? || category.empty?
    errors.add(:name, 'cannot be empty') if name.nil? || name.empty?
    errors.add(:price, 'must be positive') if price.nil? || price <= 0
    errors.add(:currency, 'cannot be empty') if currency.nil? || currency.empty?
  end

  # Scopes
  dataset_module do
    def available
      where(is_available: true)
    end

    def by_category(cat)
      where(category: cat).order(:name)
    end

    def categories
      select(:category).distinct.order(:category).map(:category)
    end

    def ordered_by_category
      order(:category, :name)
    end
  end

  # Instance methods

  # Format price for display (convert tyiyn to KGS)
  # e.g., 15000 -> "150.00 KGS" or "150 сом"
  def formatted_price
    kgs = price.to_f / 100
    format('%.2f %s', kgs, currency)
  end

  # Short price format (just the number)
  def price_in_kgs
    price.to_f / 100
  end

  # Toggle availability
  def toggle_availability!
    update(is_available: !is_available)
  end

  # Mark as unavailable
  def mark_unavailable!
    update(is_available: false)
  end

  # Mark as available
  def mark_available!
    update(is_available: true)
  end

  # Display name with price
  def to_s
    "#{name} - #{formatted_price}"
  end
end
