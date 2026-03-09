# frozen_string_literal: true

# Migration: Add sizes to menu_items
# Stores size-based pricing for drinks (coffee, tea)
# Items without sizes (desserts, addons) have nil sizes

Sequel.migration do
  up do
    # JSON field with prices per size
    # Example: {"small" => 13000, "medium" => 15000, "large" => 18000}
    # null = item without sizes (desserts, addons)
    add_column :menu_items, :sizes, :json
    
    # Default size for items with sizes (used for backward compatibility)
    add_column :menu_items, :default_size, String, default: 'medium'
  end
  
  down do
    drop_column :menu_items, :sizes
    drop_column :menu_items, :default_size
  end
end
