# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/bot/router'
require_relative 'support/router_spec_support'

RSpec.describe 'Router: cart and checkout' do
  include RouterSpecSupport

  let!(:latte) do
    MenuItem.create(category: 'Кофе', name: 'Латте', price: 15_000, currency: 'KGS', is_available: true,
                    sizes: { 'small' => 13_000, 'medium' => 15_000, 'large' => 19_000 }, default_size: 'medium')
  end
  let!(:croissant) do
    MenuItem.create(category: 'Десерты', name: 'Круассан', price: 12_000, currency: 'KGS', is_available: true)
  end
  let(:client) { Client.create(telegram_user_id: client_id, first_name: 'Test', orders_count: 0) }

  def cart
    Draft.get_or_create(client_id)
  end

  describe 'order items' do
    it 'keep the size, so the barista knows what to make' do
      cart.add_item_with_size(latte, 'large', 2)

      order = Order.create_from_draft(cart, client)

      item = order.order_items.first
      expect(item.item_name).to eq('Латте (L)')
      expect(item.size).to eq('large')
      expect(order.format_for_barista).to include('Латте (L) x2')
    end
  end

  describe 'confirmation' do
    it 'shows current prices and says which ones changed' do
      d = cart
      d.add_item_with_size(latte, 'medium', 1)
      d.set_step('add_comment')
      latte.update(sizes: { 'small' => 13_000, 'medium' => 17_000, 'large' => 19_000 })

      dispatch(text_msg('без сахара'))

      text = api.of(:send_message).last[:text]
      expect(text).to include('Изменилась цена: Латте (M)', '170 KGS', 'без сахара')
    end

    it 'drops items that are no longer available' do
      d = cart
      d.add_item(croissant, 1)
      d.add_item_with_size(latte, 'small', 1)
      croissant.update(is_available: false)

      dispatch(cb('skip_comment'))

      text = api.of(:send_message).last[:text]
      expect(text).to include('Больше нет в наличии: Круассан')
      expect(Draft.for_user(client_id).items.map { |i| i['name'] }).to eq(['Латте'])
    end

    it 'stores no comment when the client skips it' do
      cart.add_item(croissant, 1)

      dispatch(cb('skip_comment'))

      expect(Draft.for_user(client_id).comment).to be_nil
    end
  end

  describe '"✅ Да"' do
    before do
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
        .and_return({ 'data' => { 'invoice_id' => 'INV-CHK', 'paylink_url' => 'https://pay' } })
    end

    it 'asks to confirm again instead of charging a price the client has not seen' do
      cart.add_item(croissant, 1)
      croissant.update(price: 14_000)

      dispatch(cb('confirm_yes'))

      expect(Order.count).to eq(0)
      expect(api.of(:send_message).last[:text]).to include('Изменилась цена', 'Подтвердить заказ?')

      dispatch(cb('confirm_yes'))
      expect(Order.first.total_amount).to eq(14_000)
    end

    it 'shows a neutral message when the invoice cannot be created' do
      cart.add_item(croissant, 1)
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
        .and_raise(MWalletError::BusinessError.new('Команда не определена', code: 1))

      dispatch(cb('confirm_yes'))

      expect(api.texts.join).to include('Не удалось создать счёт на оплату')
      expect(api.texts.join).not_to include('Команда не определена')
      expect(Draft.for_user(client_id)).not_to be_nil # the client can retry
    end
  end

  describe 'quick reorder' do
    it 'repeats sizes and quantities and skips items that are gone' do
      d = cart
      d.add_item_with_size(latte, 'small', 2)
      d.add_item(croissant, 1)
      order = Order.create_from_draft(d, client)
      Draft.clear(client_id)
      croissant.update(is_available: false)

      dispatch(cb("reorder_#{order.id}"))

      items = Draft.for_user(client_id).items
      expect(items.map { |i| [i['display_name'], i['size'], i['qty']] }).to eq([['Латте (S)', 'small', 2]])
      expect(api.of(:edit_message_text).last[:text]).to include('Больше нет в наличии: Круассан')
    end
  end

  describe 'menu categories' do
    it 'match regardless of emoji in the stored name' do
      MenuItem.create(category: '🥛 Добавки', name: 'Сироп', price: 2_000, currency: 'KGS', is_available: true)

      expect(CoffeeBot::Services::MenuService.addons.map(&:name)).to eq(['Сироп'])
      expect(CoffeeBot::Services::MenuService.items_by_category('☕ Кофе').map(&:name)).to eq(['Латте'])
    end

    it 'popular items leave out unavailable ones' do
      croissant.update(is_available: false)

      expect(CoffeeBot::Services::MenuService.popular_items.map(&:name)).not_to include('Круассан')
    end
  end

  describe 'refund audit' do
    it 'records who returned the late payment' do
      order = make_order(status: OrderStatus::EXPIRED)
      order.record_late_payment!(paid_amount: 15_000)

      dispatch(cb("refund_done_#{order.id}", from: barista_id))

      operation = PaymentOperation.where(order_id: order.id).first
      expect(operation.values).to include(operation_type: 'REFUND', status: 'COMPLETED', amount: 15_000)
      expect(operation.reason).to include(barista_id.to_s)
      expect(order.payment.total_refunded).to eq(15_000)
    end
  end
end
