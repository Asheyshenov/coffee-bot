# frozen_string_literal: true

# Migration: Create order_items table
# Stores individual items within an order
# Prices are snapshotted to preserve historical data

Sequel.migration do
  up do
    create_table :order_items do
      primary_key :id
      
      # Reference to the order
      foreign_key :order_id, :orders, on_delete: :cascade, null: false
      
      # Reference to menu item (may be null if item was deleted from menu)
      # Note: SQLite doesn't support ON DELETE SET NULL, handle in application
      foreign_key :menu_item_id, :menu_items, on_delete: :no_action
      
      # Snapshot of item data at time of order
      # This ensures order history is preserved even if menu changes
      String :item_name, null: false     # e.g., "Капучино"
      Integer :qty, null: false          # Quantity ordered
      Integer :unit_price, null: false   # Price per unit in tyiyn
      Integer :line_total, null: false   # qty * unit_price
      
      # Timestamps
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
    end
    
    # Index for order lookup
    add_index :order_items, :order_id
    add_index :order_items, :menu_item_id
  end

  down do
    drop_table :order_items
  end
end
