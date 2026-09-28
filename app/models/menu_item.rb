# frozen_string_literal: true

# A menu position of a coffee shop. Drinks may have size-based prices.
# Prices are integers in tyiyn (15000 = 150 KGS).
class MenuItem < ApplicationRecord
  SIZE_LABELS = { "small" => "S", "medium" => "M", "large" => "L" }.freeze
  SIZE_ORDER = %w[small medium large].freeze
  DRINK_CATEGORIES = %w[Кофе Чай].freeze

  acts_as_tenant :tenant

  has_many :order_items, dependent: :nullify

  validates :category, :name, :currency, presence: true
  validates :price, numericality: { only_integer: true, greater_than: 0 }
  validate :sizes_are_valid

  scope :available, -> { where(available: true) }
  scope :by_category, ->(category) { where(category: category).order(:position, :name) }
  scope :ordered_by_category, -> { order(:category, :position, :name) }

  # Category names differ between menus ("Кофе", "☕ Кофе", "🥛 Добавки"):
  # they are compared without emoji, punctuation and case
  def self.category_key(name)
    name.to_s.gsub(/[^\p{L}\p{N}\s]/, "").squeeze(" ").strip.downcase
  end

  def self.same_category?(a, b) = category_key(a) == category_key(b)

  # Distinct category names of the current tenant's menu
  def self.categories
    distinct.order(:category).pluck(:category)
  end

  # Stored category name for a (possibly differently decorated) name, nil if none
  def self.find_category(name)
    categories.find { |category| same_category?(category, name) }
  end

  # "150 KGS"
  def formatted_price = format_amount(price)

  def has_sizes? = sizes.is_a?(Hash) && sizes.any?

  def drink? = DRINK_CATEGORIES.any? { |c| self.class.same_category?(c, category) }

  # Price in tyiyn for a size (default size / base price when the size is unknown)
  def price_for_size(size = nil)
    return price unless has_sizes?

    sizes[size.to_s] || sizes[default_size.to_s] || price
  end

  def formatted_price_for_size(size = nil) = format_amount(price_for_size(size))

  # Name with size label for carts and orders, e.g. "Латте (M)"
  def display_name_for_size(size)
    return name unless size && has_sizes?

    "#{name} (#{SIZE_LABELS[size.to_s] || size.to_s.upcase})"
  end

  # [{size:, label:, price:, formatted_price:}] in S/M/L order
  def size_options
    return [] unless has_sizes?

    SIZE_ORDER.filter_map do |size|
      next unless sizes.key?(size)

      { size: size, label: SIZE_LABELS[size], price: sizes[size], formatted_price: formatted_price_for_size(size) }
    end
  end

  # "S 130 KGS | M 150 KGS | L 190 KGS"
  def formatted_prices
    return formatted_price unless has_sizes?

    size_options.map { |opt| "#{opt[:label]} #{opt[:formatted_price]}" }.join(" | ")
  end

  def to_s = "#{name} - #{formatted_prices}"

  private

  def format_amount(amount) = format("%d %s", amount.to_i / 100, currency)

  def sizes_are_valid
    return if sizes.nil?
    return errors.add(:sizes, "must be a hash of size => price") unless sizes.is_a?(Hash)

    sizes.each do |size, amount|
      errors.add(:sizes, "unknown size #{size}") unless SIZE_LABELS.key?(size.to_s)
      errors.add(:sizes, "price for #{size} must be a positive integer") unless amount.is_a?(Integer) && amount.positive?
    end
  end
end
