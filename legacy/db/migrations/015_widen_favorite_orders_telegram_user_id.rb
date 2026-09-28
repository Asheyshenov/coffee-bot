# frozen_string_literal: true

# Migration: favorite_orders.telegram_user_id Integer -> bigint
#
# 012 declared it as Integer, which is a 32-bit `integer` on PostgreSQL, while
# Telegram user ids no longer fit into it (e.g. 7123456789). Every other table
# already stores Telegram ids as BigInt (clients, drafts, orders).
#
# SQLite is skipped: its INTEGER is already 64-bit, and set_column_type there
# rebuilds the table, which with foreign keys on would cascade-delete
# favorite_order_items (see 014 for the same problem with `orders`).

Sequel.migration do
  up do
    next if database_type == :sqlite

    alter_table(:favorite_orders) do
      set_column_type :telegram_user_id, :Bignum
    end
  end

  down do
    next if database_type == :sqlite

    # Fails (instead of truncating) if ids above the 32-bit range are stored
    alter_table(:favorite_orders) do
      set_column_type :telegram_user_id, Integer
    end
  end
end
