# frozen_string_literal: true

# Migration: Create drafts table
# Stores the current order wizard state for each user
# This ensures cart state persists across bot restarts

Sequel.migration do
  up do
    create_table :drafts do
      primary_key :id
      
      # One draft per user
      BigInt :telegram_user_id, unique: true, null: false
      
      # JSON string containing the wizard state:
      # {
      #   "step": "select_category" | "select_item" | "select_qty" | "cart",
      #   "category": "Кофе",
      #   "items": [
      #     {"menu_item_id": 1, "name": "Капучино", "price": 15000, "qty": 2}
      #   ],
      #   "comment": "Без сахара"
      # }
      String :state_json, text: true, null: false
      
      # Timestamps
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at
    end
    
    # Index for quick lookup by user
    add_index :drafts, :telegram_user_id, unique: true
  end

  down do
    drop_table :drafts
  end
end
