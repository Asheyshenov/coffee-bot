# frozen_string_literal: true

# 1. order_items.size: the size (small/medium/large) of the ordered drink, so an
#    order can be repeated with the same sizes.
# 2. Databases created from an earlier version of migration 007 have
#    payment_operations.payment_id instead of order_id (schema drift in old dev DBs).
#    Such a table is rebuilt to the 007 layout; existing rows are kept (order_id is
#    taken from the payment). Fresh databases are not touched.
#
# Only plain ADD COLUMN / CREATE / DROP / RENAME are used: on SQLite Sequel's
# alter_table emulation would rebuild tables and drop the orders status triggers.

Sequel.migration do
  up do
    unless schema(:order_items).any? { |column, _| column == :size }
      alter_table(:order_items) { add_column :size, String }
    end

    columns = schema(:payment_operations).map(&:first)
    if columns.include?(:payment_id) && !columns.include?(:order_id)
      rows = from(:payment_operations)
             .join(:payments, id: :payment_id)
             .select_all(:payment_operations)
             .select_append(Sequel[:payments][:order_id])
             .all

      create_table(:payment_operations_007) do
        primary_key :id
        foreign_key :order_id, :orders, on_delete: :cascade, null: false
        String :operation_type, null: false
        String :operation_id_provider
        Integer :amount, null: false
        String :reason
        String :status, null: false, default: 'PENDING'
        DateTime :created_at, null: false, default: Sequel::CURRENT_TIMESTAMP
        DateTime :updated_at
        String :raw_request, text: true
        String :raw_response, text: true
      end

      rows.each do |row|
        from(:payment_operations_007).insert(
          order_id: row[:order_id],
          operation_type: row[:operation_type],
          amount: row[:amount] || 0,
          status: row[:status],
          raw_response: row[:provider_response],
          created_at: row[:created_at] || Sequel::CURRENT_TIMESTAMP,
          updated_at: row[:updated_at]
        )
      end

      drop_table(:payment_operations)
      rename_table(:payment_operations_007, :payment_operations)
      add_index :payment_operations, :order_id
      add_index :payment_operations, [:operation_type, :status]
    end
  end

  down do
    # The payment_operations rebuild is not reversed (the old layout was a bug)
    alter_table(:order_items) { drop_column :size } if schema(:order_items).any? { |column, _| column == :size }
  end
end
