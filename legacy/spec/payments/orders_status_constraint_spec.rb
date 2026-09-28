# frozen_string_literal: true

require_relative 'payments_helper'

RSpec.describe 'orders.status database constraint (migration 014)' do
  include PaymentsSpec::Helpers

  describe 'on the test database' do
    it 'rejects values outside OrderStatus::ALL on update and insert' do
      order = make_order

      expect { order.this.update(status: 'cancelled') }.to raise_error(Sequel::CheckConstraintViolation)
      expect do
        DB[:orders].insert(merchant_invoice_id: 'M-BOGUS', telegram_user_id: 1, client_display_name: 'T',
                           status: 'bogus', total_amount: 100)
      end.to raise_error(Sequel::CheckConstraintViolation)
      expect(order.refresh.status).to eq(OrderStatus::INVOICE_CREATED)
    end

    it 'accepts every OrderStatus::ALL value' do
      order = make_order
      OrderStatus::ALL.each do |status|
        expect { order.this.update(status: status) }.not_to raise_error
      end
    end
  end

  describe 'migrating existing data (fresh in-memory database)' do
    let(:migrations_dir) { File.expand_path('../../db/migrations', __dir__) }
    let(:db) { Sequel.sqlite }
    let(:old_time) { Time.utc(2026, 1, 1, 12, 0, 0) }

    after do
      db.disconnect
      Sequel::DATABASES.delete(db)
    end

    # Same options as CoffeeBot::DB.run_migrations! (every migration in a transaction)
    def migrate(target)
      Sequel::Migrator.run(db, migrations_dir, target: target, use_transactions: true)
    end

    def seed_orders(statuses)
      statuses.map do |status|
        id = db[:orders].insert(merchant_invoice_id: "M-#{status}", telegram_user_id: 1, client_display_name: 'T',
                                status: status, total_amount: 100, created_at: old_time, updated_at: old_time)
        db[:order_items].insert(order_id: id, item_name: 'Латте', qty: 1, unit_price: 100, line_total: 100)
        db[:payments].insert(order_id: id, paid_amount: 100, status: 'PAID')
        id
      end
    end

    it 'normalises invalid statuses and keeps order_items / payments attached' do
      migrate(13)
      ids = seed_orders(%w[cancelled Paid canceled weird READY])

      migrate(14)

      expect(db[:orders].order(:id).select_map(:status)).to eq(%w[CANCELLED PAID CANCELLED ERROR READY])
      expect(db[:orders].select_map(:updated_at).uniq).to eq([old_time])
      expect(db[:order_items].select_order_map(:order_id)).to eq(ids)
      expect(db[:payments].select_order_map(:order_id)).to eq(ids)
      expect(db.fetch('PRAGMA foreign_key_check').all).to be_empty
      expect { db[:orders].where(id: ids.first).update(status: 'cancelled') }
        .to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'can be rolled back' do
      migrate(14)
      migrate(13)

      expect { seed_orders(%w[cancelled]) }.not_to raise_error
    end
  end
end
