# frozen_string_literal: true

# Migration: Normalise orders.status and enforce valid values in the database
#
# 1. Fix invalid values already stored (the dev DB has lowercase 'cancelled'):
#    case-insensitive match to a valid status ('CANCELED' -> 'CANCELLED'),
#    anything unknown -> 'ERROR'. updated_at is deliberately left untouched,
#    so old orders don't look recently changed (StatusSyncer late-payment window).
#
# 2. Enforce status IN (OrderStatus::ALL):
#    - PostgreSQL (and other databases): a real CHECK constraint.
#    - SQLite: BEFORE INSERT / UPDATE triggers raising "CHECK constraint failed",
#      which Sequel maps to Sequel::CheckConstraintViolation just like a real CHECK.
#      A real CHECK needs Sequel's alter_table emulation (rebuild of `orders`), and
#      the Migrator runs every migration inside a transaction (use_transactions: true)
#      where SQLite ignores PRAGMA foreign_keys = OFF. Rebuilding `orders` with foreign
#      keys on cascades into order_items / payments: on a copy of the dev DB this
#      deleted 65 of 68 order_items and all 17 payments.
#      Keep in mind: any future SQLite rebuild of `orders` drops these triggers.

Sequel.migration do
  up do
    # Same values as OrderStatus::ALL at the time of writing
    statuses = %w[NEW INVOICE_CREATED PAID IN_PROGRESS READY CANCELLED EXPIRED ERROR]
    aliases = { 'CANCELED' => 'CANCELLED' }

    from(:orders).exclude(status: statuses).distinct.select_map(:status).each do |invalid|
      normalised = invalid.to_s.strip.upcase
      normalised = aliases.fetch(normalised, normalised)
      normalised = 'ERROR' unless statuses.include?(normalised)

      from(:orders).where(status: invalid).update(status: normalised)
    end

    if database_type == :sqlite
      allowed = statuses.map { |s| literal(s) }.join(', ')
      raise_sql = "SELECT RAISE(ABORT, 'CHECK constraint failed: orders_status_check')"

      run <<~SQL
        CREATE TRIGGER orders_status_check_insert BEFORE INSERT ON orders
        FOR EACH ROW WHEN NEW.status NOT IN (#{allowed})
        BEGIN #{raise_sql}; END
      SQL

      run <<~SQL
        CREATE TRIGGER orders_status_check_update BEFORE UPDATE OF status ON orders
        FOR EACH ROW WHEN NEW.status NOT IN (#{allowed})
        BEGIN #{raise_sql}; END
      SQL
    else
      alter_table(:orders) do
        add_constraint(:orders_status_check, status: statuses)
      end
    end
  end

  down do
    # Status normalisation is not reverted (original invalid values are not kept)
    if database_type == :sqlite
      run 'DROP TRIGGER IF EXISTS orders_status_check_insert'
      run 'DROP TRIGGER IF EXISTS orders_status_check_update'
    else
      alter_table(:orders) do
        drop_constraint(:orders_status_check)
      end
    end
  end
end
