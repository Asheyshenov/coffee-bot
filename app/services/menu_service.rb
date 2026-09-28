# frozen_string_literal: true

# Menu queries of the current coffee shop, and the default menu of a new one
class MenuService
  POPULAR_LIMIT = 5
  ADDONS_CATEGORY = "Добавки"

  # Default menu of a new coffee shop (prices in tyiyn)
  DEFAULT_MENU = [
    { category: "Кофе", name: "Эспрессо", price: 8000,
      sizes: { "small" => 8000, "medium" => 10_000, "large" => 12_000 }, default_size: "medium" },
    { category: "Кофе", name: "Американо", price: 10_000,
      sizes: { "small" => 10_000, "medium" => 12_000, "large" => 15_000 }, default_size: "medium" },
    { category: "Кофе", name: "Капучино", price: 15_000,
      sizes: { "small" => 13_000, "medium" => 15_000, "large" => 18_000 }, default_size: "medium" },
    { category: "Кофе", name: "Латте", price: 16_000,
      sizes: { "small" => 14_000, "medium" => 16_000, "large" => 19_000 }, default_size: "medium" },
    { category: "Кофе", name: "Раф", price: 18_000,
      sizes: { "small" => 16_000, "medium" => 18_000, "large" => 22_000 }, default_size: "medium" },
    { category: "Кофе", name: "Флэт Уайт", price: 17_000,
      sizes: { "small" => 15_000, "medium" => 17_000, "large" => 20_000 }, default_size: "medium" },
    { category: "Чай", name: "Чёрный чай", price: 8000,
      sizes: { "small" => 6000, "medium" => 8000, "large" => 10_000 }, default_size: "medium" },
    { category: "Чай", name: "Зелёный чай", price: 8000,
      sizes: { "small" => 6000, "medium" => 8000, "large" => 10_000 }, default_size: "medium" },
    { category: "Чай", name: "Чай с молоком", price: 10_000,
      sizes: { "small" => 9000, "medium" => 10_000, "large" => 12_000 }, default_size: "medium" },
    { category: "Чай", name: "Матча латте", price: 18_000,
      sizes: { "small" => 16_000, "medium" => 18_000, "large" => 22_000 }, default_size: "medium" },
    { category: "Десерты", name: "Круассан", price: 12_000 },
    { category: "Десерты", name: "Маффин", price: 10_000 },
    { category: "Десерты", name: "Чизкейк", price: 20_000 },
    { category: "Добавки", name: "Сироп", price: 2000 },
    { category: "Добавки", name: "Молоко", price: 3000 },
    { category: "Добавки", name: "Взбитые сливки", price: 5000 }
  ].freeze

  # @return [Array<String>] category names as stored in the menu
  def self.categories = MenuItem.categories

  # Items of a category; the name is matched without emoji ("☕ Кофе" finds "Кофе")
  #
  # @return [Array<MenuItem>]
  def self.items_by_category(category, available_only: true)
    items = MenuItem.by_category(MenuItem.find_category(category) || category)
    items = items.available if available_only
    items.to_a
  end

  def self.available_items = MenuItem.available.ordered_by_category.to_a

  # @return [MenuItem, nil] also unavailable items (callers check #available?)
  def self.find_item(id) = MenuItem.find_by(id: id)

  # Most ordered available items
  #
  # @return [Array<MenuItem>]
  def self.popular_items(limit: POPULAR_LIMIT)
    MenuItem.available
            .left_joins(:order_items)
            .group(:id)
            .order(Arel.sql("COUNT(order_items.id) DESC"), :category, :position, :name)
            .limit(limit)
            .to_a
  end

  # @return [Array<MenuItem>] available items of the add-ons category
  def self.addons
    category = MenuItem.find_category(ADDONS_CATEGORY)
    return [] unless category

    MenuItem.available.by_category(category).to_a
  end

  # Create the default menu for a new coffee shop. Does nothing if the shop already
  # has a menu. Works with or without a current tenant.
  #
  # @return [Integer] number of items created
  def self.seed_menu(tenant)
    ActsAsTenant.with_tenant(tenant) do
      if MenuItem.exists?
        0
      else
        MenuItem.transaction do
          DEFAULT_MENU.group_by { |item| item[:category] }.each_value do |items|
            items.each_with_index { |attrs, position| MenuItem.create!(attrs.merge(position: position)) }
          end
        end
        AppLog.info("Menu seeded", count: DEFAULT_MENU.size)
        DEFAULT_MENU.size
      end
    end
  end
end
