# frozen_string_literal: true

# MenuItem Model
# Represents a menu item in the coffee shop
# Supports size-based pricing for drinks (coffee, tea)

require_relative '../../config/boot'
require 'json'

class MenuItem < Sequel::Model
  # Handle JSON serialization for sizes column (SQLite compatibility)
  plugin :serialization, :json, :sizes
  
  # Categories that support sizes
  DRINK_CATEGORIES = %w[Кофе Чай].freeze
  
  # Size labels for display
  SIZE_LABELS = {
    'small' => 'S',
    'medium' => 'M',
    'large' => 'L'
  }.freeze
  
  # Size order for consistent display
  SIZE_ORDER = %w[small medium large].freeze

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
  # e.g., 15000 -> "150 KGS" or "150 сом"
  def formatted_price
    kgs = price.to_i / 100
    format('%d %s', kgs, currency)
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

  # === Size-related methods ===

  # Check if item has size options
  # @return [Boolean] true if item has sizes
  def has_sizes?
    sizes.is_a?(Hash) && !sizes.empty?
  end

  # Check if item is a drink (category supports sizes)
  # @return [Boolean] true if drink category
  def drink?
    DRINK_CATEGORIES.include?(category)
  end

  # Get price for specific size
  # @param size [String, nil] Size key (small, medium, large)
  # @return [Integer] Price in tyiyn
  def price_for_size(size = nil)
    return price unless has_sizes?
    
    if size && sizes[size]
      sizes[size]
    else
      # Fall back to default size or base price
      sizes[default_size] || price
    end
  end

  # Format price for specific size
  # @param size [String, nil] Size key
  # @return [String] Formatted price string
  def formatted_price_for_size(size = nil)
    kgs = price_for_size(size).to_i / 100
    format('%d %s', kgs, currency)
  end

  # Get all sizes with prices
  # @return [Array<Hash>] Array of {size, label, price, formatted_price}
  def size_options
    return [] unless has_sizes?
    
    s = sizes  # Already deserialized by Sequel serialization plugin
    SIZE_ORDER.map do |size|
      next unless s.key?(size)
      
      {
        size: size,
        label: SIZE_LABELS[size],
        price: s[size],
        formatted_price: formatted_price_for_size(size)
      }
    end.compact
  end

  # Format all prices for display (e.g., "S 130 | M 150 | L 190")
  # @return [String] Combined price string
  def formatted_prices
    return formatted_price unless has_sizes?
    
    size_options.map do |opt|
      "#{opt[:label]} #{opt[:formatted_price]}"
    end.join(' | ')
  end

  # Display name with price (or prices if has sizes)
  def to_s
    if has_sizes?
      "#{name} - #{formatted_prices}"
    else
      "#{name} - #{formatted_price}"
    end
  end
end
