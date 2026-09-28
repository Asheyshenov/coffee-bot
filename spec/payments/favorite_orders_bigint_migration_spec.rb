# frozen_string_literal: true

require_relative 'payments_helper'

RSpec.describe 'favorite_orders.telegram_user_id as bigint (migration 015)' do
  let(:migration_path) do
    File.expand_path('../../db/migrations/015_widen_favorite_orders_telegram_user_id.rb', __dir__)
  end
  # Telegram ids of accounts created since ~2021 do not fit into a 32-bit integer
  let(:big_telegram_id) { 7_000_000_000 }

  # Load the migration the same way Sequel::Migrator does, without registering it
  def load_migration
    load(migration_path)
    Sequel::Migration.descendants.pop
  end

  it 'widens the column to bigint on PostgreSQL' do
    db = Sequel.mock(host: 'postgres')

    load_migration.apply(db, :up)

    expect(db.sqls).to include('ALTER TABLE "favorite_orders" ALTER COLUMN "telegram_user_id" TYPE bigint')
  ensure
    Sequel::DATABASES.delete(db)
  end

  it 'does nothing on SQLite (INTEGER is 64-bit, no table rebuild)' do
    db = Sequel.mock(host: 'sqlite')

    load_migration.apply(db, :up)
    load_migration.apply(db, :down)

    expect(db.sqls).to be_empty
  ensure
    Sequel::DATABASES.delete(db)
  end

  it 'stores a favorite of a user with a Telegram id above the 32-bit range' do
    favorite = FavoriteOrder.create(telegram_user_id: big_telegram_id, title: 'Утренний')

    expect(FavoriteOrder[favorite.id].telegram_user_id).to eq(big_telegram_id)
    expect(FavoriteOrder.for_user(big_telegram_id).map(&:id)).to eq([favorite.id])
  end
end
