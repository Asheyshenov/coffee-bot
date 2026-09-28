# frozen_string_literal: true

# update_id of every accepted Telegram update: Telegram redelivers an update when our
# response was lost or slow, and it must not be handled twice (a second cart line...)
class CreateTelegramUpdates < ActiveRecord::Migration[8.1]
  def change
    create_table :telegram_updates do |t|
      t.references :bot, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :update_id, null: false
      t.datetime :created_at, null: false
      t.index [ :bot_id, :update_id ], unique: true
      t.index :created_at
    end
  end
end
