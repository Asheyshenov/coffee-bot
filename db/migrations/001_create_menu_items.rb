# frozen_string_literal: true

# Migration: Create menu_items table
# Stores the coffee shop menu with categories and prices

Sequel.migration do
  up do
    create_table :menu_items do
      primary_key :id
      
      # Category for grouping items (e.g., "Кофе", "Чай", "Десерты")
      String :category, null: false
      
      # Item name (e.g., "Капучино", "Латте")
      String :name, null: false
      
      # Price in tyiyn (smallest currency unit)
      # 1 KGS = 100 tyiyn, so 15000 = 150 KGS
      Integer :price, null: false
      
      # Currency code
      String :currency, default: 'KGS'
      
      # Availability flag - can be toggled off when item is out of stock
      TrueClass :is_available, default: true
      
      # Timestamps
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at
    end

    # Add index on category for faster filtering
    add_index :menu_items, :category
    
    # Add index on availability for filtering available items
    add_index :menu_items, :is_available
  end

  down do
    drop_table :menu_items
  end
end
