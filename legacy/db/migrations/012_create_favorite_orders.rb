# Migration: Create favorite_orders table
# Stores user's favorite order templates for quick reordering

Sequel.migration do
  change do
    create_table(:favorite_orders) do
      primary_key :id
      Integer :telegram_user_id, null: false, index: true
      String :title, null: false, size: 255
      String :comment, size: 500
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      DateTime :last_used_at
      
      index [:telegram_user_id, :created_at], name: :idx_favorite_orders_user_created
    end
  end
end
