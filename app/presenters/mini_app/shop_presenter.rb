# frozen_string_literal: true

module MiniApp
  # GET /app/:bot_id/api/shop: the coffee shop and its available menu, in menu order
  class ShopPresenter
    # Size used when a sized item is added without one: the item's default size if it
    # has a price for it, else its first size (nil for items without sizes)
    def self.default_size(item)
      return nil unless item.has_sizes?

      item.sizes.key?(item.default_size.to_s) ? item.default_size.to_s : item.size_options.first&.dig(:size)
    end

    # @param tenant [Tenant]
    # @param items [Array<MenuItem>] available items ordered by category, position, name
    def initialize(tenant, items)
      @tenant = tenant
      @items = items
    end

    def as_json(*)
      {
        shop: { name: @tenant.name, currency: currency, order_expire_minutes: @tenant.order_expire_minutes },
        categories: @items.map(&:category).uniq.map { |name| { name: name, key: MenuItem.category_key(name) } },
        items: @items.map { |item| item_json(item) }
      }
    end

    private

    # Orders are issued in KGS (see Order.create_from_draft)
    def currency = "KGS"

    def item_json(item)
      default_size = self.class.default_size(item)
      {
        id: item.id,
        category: item.category,
        name: item.name,
        description: item.description.presence,
        price: item.price_for_size(default_size),
        default_size: default_size,
        sizes: item.size_options.map { |option| option.slice(:size, :label, :price) }
      }
    end
  end
end
