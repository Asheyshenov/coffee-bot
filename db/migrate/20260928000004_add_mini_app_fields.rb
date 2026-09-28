# frozen_string_literal: true

# Telegram Mini App: an app link to pay in O!Dengi (opens the wallet app on the phone)
# and an optional description for menu cards.
class AddMiniAppFields < ActiveRecord::Migration[8.1]
  def change
    add_column :orders, :payment_app_url, :text
    add_column :menu_items, :description, :text
  end
end
