# frozen_string_literal: true

# Menu Service
# Handles menu item management and display

require_relative '../../config/boot'

module CoffeeBot
  module Services
    class MenuService
      # Get all available categories
      #
      # @return [Array<String>] List of category names
      def self.categories
        MenuItem.categories
      end

      # Get all items in a category
      #
      # @param category [String] Category name
      # @param available_only [Boolean] Only return available items
      # @return [Array<MenuItem>] List of menu items
      def self.items_by_category(category, available_only: true)
        items = MenuItem.by_category(category)
        items = items.available if available_only
        items.all
      end

      # Get all available items
      #
      # @return [Array<MenuItem>] List of available menu items
      def self.available_items
        MenuItem.available.ordered_by_category.all
      end

      # Get item by ID
      #
      # @param id [Integer] Menu item ID
      # @return [MenuItem, nil] The menu item or nil
      def self.find_item(id)
        MenuItem[id]
      end

      # Create new menu item
      #
      # @param params [Hash] Menu item attributes
      # @return [MenuItem] Created menu item
      def self.create_item(params)
        MenuItem.create(
          category: params[:category],
          name: params[:name],
          price: params[:price], # Should be in tyiyn
          currency: params[:currency] || 'KGS',
          is_available: params[:is_available] != false,
          sizes: params[:sizes],
          default_size: params[:default_size]
        )
      end

      # Update menu item
      #
      # @param id [Integer] Menu item ID
      # @param params [Hash] Attributes to update
      # @return [MenuItem, nil] Updated menu item
      def self.update_item(id, params)
        item = MenuItem[id]
        return nil unless item
        
        item.update(params)
        item
      end

      # Toggle item availability
      #
      # @param id [Integer] Menu item ID
      # @return [Boolean] New availability state
      def self.toggle_availability(id)
        item = MenuItem[id]
        return nil unless item
        
        item.toggle_availability!
        item.is_available
      end

      # Delete menu item
      #
      # @param id [Integer] Menu item ID
      # @return [Boolean] True if deleted
      def self.delete_item(id)
        item = MenuItem[id]
        return false unless item
        
        item.destroy
        true
      end

      # Format menu for display
      #
      # @param available_only [Boolean] Only show available items
      # @return [String] Formatted menu text
      def self.format_menu(available_only: true)
        items = available_only ? available_items : MenuItem.ordered_by_category.all
        
        return 'Меню пустое' if items.empty?

        lines = []
        current_category = nil

        items.each do |item|
          if current_category != item.category
            current_category = item.category
            lines << ''
            lines << "☕ #{current_category}"
            lines << '─' * 20
          end

          status = item.is_available ? '' : ' ❌'
          lines << "#{item.name} - #{item.formatted_price}#{status}"
        end

        lines.join("\n")
      end

      # Format category for display
      #
      # @param category [String] Category name
      # @return [String] Formatted category text
      def self.format_category(category)
        items = items_by_category(category)
        
        return "Категория '#{category}' пуста" if items.empty?

        lines = ["☕ #{category}", '─' * 20]
        
        items.each_with_index do |item, idx|
          lines << "#{idx + 1}. #{item.name} - #{item.formatted_price}"
        end

        lines.join("\n")
      end

      # Get menu statistics
      #
      # @return [Hash] Statistics about menu
      def self.statistics
        total = MenuItem.count
        available = MenuItem.available.count
        categories = MenuItem.categories.count
        
        {
          total_items: total,
          available_items: available,
          unavailable_items: total - available,
          categories: categories
        }
      end

      # Seed initial menu data (for development/testing)
      def self.seed_menu
        return if MenuItem.count > 0

        items = [
          # Coffee with sizes
          {
            category: 'Кофе',
            name: 'Эспрессо',
            price: 8000,
            sizes: { 'small' => 8000, 'medium' => 10000, 'large' => 12000 },
            default_size: 'medium'
          },
          {
            category: 'Кофе',
            name: 'Американо',
            price: 10000,
            sizes: { 'small' => 10000, 'medium' => 12000, 'large' => 15000 },
            default_size: 'medium'
          },
          {
            category: 'Кофе',
            name: 'Капучино',
            price: 15000,
            sizes: { 'small' => 13000, 'medium' => 15000, 'large' => 18000 },
            default_size: 'medium'
          },
          {
            category: 'Кофе',
            name: 'Латте',
            price: 16000,
            sizes: { 'small' => 14000, 'medium' => 16000, 'large' => 19000 },
            default_size: 'medium'
          },
          {
            category: 'Кофе',
            name: 'Раф',
            price: 18000,
            sizes: { 'small' => 16000, 'medium' => 18000, 'large' => 22000 },
            default_size: 'medium'
          },
          {
            category: 'Кофе',
            name: 'Флэт Уайт',
            price: 17000,
            sizes: { 'small' => 15000, 'medium' => 17000, 'large' => 20000 },
            default_size: 'medium'
          },
          # Tea with sizes
          {
            category: 'Чай',
            name: 'Чёрный чай',
            price: 8000,
            sizes: { 'small' => 6000, 'medium' => 8000, 'large' => 10000 },
            default_size: 'medium'
          },
          {
            category: 'Чай',
            name: 'Зелёный чай',
            price: 8000,
            sizes: { 'small' => 6000, 'medium' => 8000, 'large' => 10000 },
            default_size: 'medium'
          },
          {
            category: 'Чай',
            name: 'Чай с молоком',
            price: 10000,
            sizes: { 'small' => 9000, 'medium' => 10000, 'large' => 12000 },
            default_size: 'medium'
          },
          {
            category: 'Чай',
            name: 'Матча латте',
            price: 18000,
            sizes: { 'small' => 16000, 'medium' => 18000, 'large' => 22000 },
            default_size: 'medium'
          },
          # Desserts without sizes
          { category: 'Десерты', name: 'Круассан', price: 12000 },
          { category: 'Десерты', name: 'Маффин', price: 10000 },
          { category: 'Десерты', name: 'Чизкейк', price: 20000 },
          # Addons without sizes
          { category: 'Добавки', name: 'Сироп', price: 2000 },
          { category: 'Добавки', name: 'Молоко', price: 3000 },
          { category: 'Добавки', name: 'Взбитые сливки', price: 5000 }
        ]

        items.each do |item_data|
          create_item(item_data)
        end

        log_info('Menu seeded', count: items.length)
      end

      # Get popular items (most ordered)
      #
      # @return [Array<MenuItem>] List of popular items
      def self.popular_items
        # Join with order_items to get order count, ordered by popularity
        MenuItem
          .select(
            Sequel.qualify(:menu_items, :id),
            Sequel.qualify(:menu_items, :name),
            Sequel.qualify(:menu_items, :category),
            Sequel.qualify(:menu_items, :price),
            Sequel.qualify(:menu_items, :is_available),
            Sequel.qualify(:menu_items, :sizes),
            Sequel.qualify(:menu_items, :default_size),
            Sequel.qualify(:menu_items, :currency),
            Sequel.function(:count, Sequel.qualify(:order_items, :id)).as(:order_count)
          )
          .left_join(:order_items, menu_item_id: :id)
          .group_by(Sequel.qualify(:menu_items, :id))
          .order(Sequel.desc(:order_count))
          .limit(5)
          .all
      end

      # Get all available addons
      #
      # @return [Array<MenuItem>] List of addon items
      def self.addons
        MenuItem.where(category: 'Добавки', is_available: true).all
      end
    end
  end
end
