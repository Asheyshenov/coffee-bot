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
          is_available: params[:is_available] != false
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
          { category: 'Кофе', name: 'Эспрессо', price: 8000 },
          { category: 'Кофе', name: 'Американо', price: 10000 },
          { category: 'Кофе', name: 'Капучино', price: 15000 },
          { category: 'Кофе', name: 'Латте', price: 16000 },
          { category: 'Кофе', name: 'Раф', price: 18000 },
          { category: 'Кофе', name: 'Флэт Уайт', price: 17000 },
          { category: 'Чай', name: 'Чёрный чай', price: 8000 },
          { category: 'Чай', name: 'Зелёный чай', price: 8000 },
          { category: 'Чай', name: 'Чай с молоком', price: 10000 },
          { category: 'Чай', name: 'Матча латте', price: 18000 },
          { category: 'Десерты', name: 'Круассан', price: 12000 },
          { category: 'Десерты', name: 'Маффин', price: 10000 },
          { category: 'Десерты', name: 'Чизкейк', price: 20000 },
          { category: 'Добавки', name: 'Сироп', price: 2000 },
          { category: 'Добавки', name: 'Молоко', price: 3000 },
          { category: 'Добавки', name: 'Взбитые сливки', price: 5000 }
        ]

        items.each do |item_data|
          create_item(item_data)
        end

        log_info('Menu seeded', count: items.length)
      end
    end
  end
end
