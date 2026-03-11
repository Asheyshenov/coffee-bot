# Migration: Create favorite_order_items table
# Stores individual items within favorite order templates

Sequel.migration do
  change do
    create_table(:favorite_order_items) do
      primary_key :id
      foreign_key :favorite_order_id, :favorite_orders, on_delete: :cascade, index: true
      Integer :menu_item_id, null: false, index: true
      String :item_name_snapshot, null: false, size: 255
      Integer :qty, null: false, default: 1
      String :size, size: 50
      Integer :unit_price_snapshot, null: false  # Price at time of saving (for reference only)
      String :addons_json, text: true  # JSON array of addons
      String :comment, size: 500
      
      index [:favorite_order_id], name: :idx_favorite_order_items_favorite
    end
  end
end
