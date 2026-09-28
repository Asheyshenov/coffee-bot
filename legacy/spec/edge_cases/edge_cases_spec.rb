# frozen_string_literal: true

# Edge-case audit suite.
# Every example asserts the CORRECT/EXPECTED behaviour, so a failing example = a found bug.
# Network is fully disabled; Telegram is replaced with a recording fake.

require_relative '../spec_helper'
require_relative '../../lib/bot/router'
require_relative '../../lib/http/callback_app'
require_relative '../../lib/jobs/status_syncer'
require_relative '../../lib/jobs/invoice_expirer'

# Records every Telegram API call. Mimics Telegram rejecting a second answer for the same callback query.
class FakeTelegramApi
  attr_reader :calls

  def initialize
    @calls = []
    @answered = {}
  end

  def method_missing(name, **kwargs)
    if name == :answer_callback_query
      id = kwargs[:callback_query_id]
      if @answered[id]
        # Real Telegram raises 400 here; we only record it so each example tests its own concern.
        @calls << [:answer_callback_query_rejected, kwargs]
        return { 'ok' => false }
      end
      @answered[id] = true
    end
    @calls << [name, kwargs]
    { 'ok' => true }
  end

  def respond_to_missing?(*) = true

  def texts
    calls.map { |(_, kw)| kw[:text] }.compact
  end

  def of(name)
    calls.select { |(n, _)| n == name }.map(&:last)
  end
end

class FakeResponse
  def status = 400
  def body = '{"ok":false,"error_code":400,"description":"Bad Request: query is too old or query ID is invalid"}'
  def env = nil
end

FakeBot = Struct.new(:api)

RSpec.describe 'Edge cases audit' do
  let(:api) { FakeTelegramApi.new }
  let(:router) { CoffeeBot::Bot::Router.new(FakeBot.new(api)) }
  let(:client_id) { 1001 }
  let(:barista_id) { 2002 }
  let(:stranger_id) { 3003 }

  let!(:latte) do
    MenuItem.create(category: '☕ Кофе', name: 'Латте', price: 15_000, currency: 'KGS', is_available: true,
                    sizes: { 'small' => 13_000, 'medium' => 15_000, 'large' => 19_000 }, default_size: 'medium')
  end
  let!(:croissant) do
    MenuItem.create(category: '🍰 Десерты', name: 'Круассан', price: 12_000, currency: 'KGS', is_available: true)
  end

  before do
    # Hard network kill switch: nothing may leave the test process.
    allow_any_instance_of(Faraday::Connection).to receive(:run_request).and_raise('NETWORK DISABLED IN TESTS')
    stub_const('CoffeeBot::Config::BARISTA_WHITELIST', [barista_id])
    allow(Telegram::Bot::Client).to receive(:new).and_return(FakeBot.new(api))
  end

  # ---------- helpers ----------
  def user(id) = { id: id, is_bot: false, first_name: "U#{id}" }
  def chat(id) = { id: id, type: 'private' }

  def text_msg(text, from: client_id)
    Telegram::Bot::Types::Message.new(message_id: rand(1..10_000), date: 0, chat: chat(from), from: user(from), text: text)
  end

  def non_text_msg(from: client_id)
    Telegram::Bot::Types::Message.new(message_id: rand(1..10_000), date: 0, chat: chat(from), from: user(from))
  end

  def cb(data, from: client_id, id: "q#{rand(1_000_000)}")
    Telegram::Bot::Types::CallbackQuery.new(
      id: id, from: user(from), chat_instance: 'x', data: data,
      message: { message_id: 77, date: 0, chat: chat(from) }
    )
  end

  def dispatch(update)
    router.send(:handle_message, update)
  end

  def dispatch_like_listen_loop(update)
    dispatch(update)
  rescue StandardError => e
    e # router.run swallows errors; we return it for inspection
  end

  def make_order(status: OrderStatus::INVOICE_CREATED, user_id: client_id, total: 15_000, invoice: 'INV-1')
    o = Order.create(telegram_user_id: user_id, client_display_name: 'Test', status: status,
                     total_amount: total, currency: 'KGS', merchant_invoice_id: Order.generate_merchant_invoice_id,
                     invoice_id_provider: invoice)
    OrderItem.create(order_id: o.id, menu_item_id: latte.id, item_name: 'Латте', qty: 1,
                     unit_price: total, line_total: total)
    o
  end

  def draft_with_latte(user_id: client_id, qty: 1)
    d = Draft.get_or_create(user_id)
    d.add_item_with_size(latte, 'medium', qty)
    d
  end

  def signed(params)
    MWallet::Signer.new(CoffeeBot::Config::MWALLET_PASSWORD.to_s.empty? ? 'test-secret' : CoffeeBot::Config::MWALLET_PASSWORD)
                   .build_signed_request(params)
  end

  # =====================================================================
  describe 'Payments: MWallet callback' do
    include Rack::Test::Methods
    def app = CoffeeBot::HTTP::CallbackApp

    before do
      stub_const('CoffeeBot::Config::MWALLET_PASSWORD', 'test-secret')
      CoffeeBot::HTTP::CallbackApp.set :host_authorization, { permitted_hosts: [] }
    end

    it 'marks an INVOICE_CREATED order as PAID on a valid signed callback' do
      order = make_order(invoice: 'INV-CB-1')
      body = signed({ 'invoice_id' => 'INV-CB-1', 'order_id' => order.merchant_invoice_id, 'status' => 3, 'amount' => 15_000 })
      post '/callbacks/mwallet/result', body.to_json, 'CONTENT_TYPE' => 'application/json'
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'accepts a second callback for the same invoice (pending -> paid) without crashing on unique event_id' do
      order = make_order(invoice: 'INV-CB-2')
      post '/callbacks/mwallet/result', signed({ 'invoice_id' => 'INV-CB-2', 'status' => 1 }).to_json, 'CONTENT_TYPE' => 'application/json'
      post '/callbacks/mwallet/result', signed({ 'invoice_id' => 'INV-CB-2', 'status' => 3, 'amount' => 15_000 }).to_json,
           'CONTENT_TYPE' => 'application/json'
      expect(JSON.parse(last_response.body)['status']).to eq('ok')
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'does NOT mark as paid when paid amount is less than the order total' do
      order = make_order(invoice: 'INV-CB-3', total: 50_000)
      # isolate from the dedupe bug so we test the amount check itself
      allow(CallbackLog).to receive(:duplicate?).and_return(false)
      body = signed({ 'invoice_id' => 'INV-CB-3', 'status' => 3, 'amount' => 100 })
      post '/callbacks/mwallet/result', body.to_json, 'CONTENT_TYPE' => 'application/json'
      expect(order.refresh.status).not_to eq(OrderStatus::PAID)
    end

    it 'rejects a callback with a forged signature (401)' do
      order = make_order(invoice: 'INV-CB-4')
      post '/callbacks/mwallet/result', { 'invoice_id' => 'INV-CB-4', 'status' => 3, 'hash' => 'deadbeef' }.to_json,
           'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(401)
      expect(order.refresh.status).to eq(OrderStatus::INVOICE_CREATED)
    end

    it 'does not leak internal exception messages in the response body' do
      allow(CoffeeBot::Services::OrderService).to receive(:process_payment_callback).and_raise(StandardError, 'PG::Secret table xyz')
      post '/callbacks/mwallet/result', '{}', 'CONTENT_TYPE' => 'application/json'
      expect(last_response.body).not_to include('PG::Secret')
    end

    it 'handles an empty body without a 500' do
      post '/callbacks/mwallet/result', '', 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to be < 500
    end

    it 'notifies the CLIENT (not only baristas) when paid via callback' do
      order = make_order(invoice: 'INV-CB-5')
      allow(CallbackLog).to receive(:duplicate?).and_return(false)
      allow(Thread).to receive(:new) { |&blk| blk.call }
      post '/callbacks/mwallet/result', signed({ 'invoice_id' => 'INV-CB-5', 'status' => 3, 'amount' => 15_000 }).to_json,
           'CONTENT_TYPE' => 'application/json'
      expect(api.of(:send_message).map { |m| m[:chat_id] }).to include(client_id)
    end
  end

  # =====================================================================
  describe 'Payments: polling (StatusSyncer)' do
    it 'does NOT mark as paid when provider reports a smaller amount than the total' do
      order = make_order(total: 50_000)
      allow_any_instance_of(MWallet::Client).to receive(:get_status)
        .and_return({ 'data' => { 'payments' => [{ 'status' => 'approved', 'amount' => 100 }] } })
      CoffeeBot::Services::OrderService.sync_payment_status(order)
      expect(order.refresh.status).not_to eq(OrderStatus::PAID)
    end

    it 'detects a payment that arrived after the order was expired (money taken, order dead)' do
      order = make_order(status: OrderStatus::EXPIRED)
      allow_any_instance_of(MWallet::Client).to receive(:get_status)
        .and_return({ 'data' => { 'payments' => [{ 'status' => 'approved', 'amount' => 15_000 }] } })
      result = CoffeeBot::Services::OrderService.sync_payment_status(order)
      # Expected: some reconciliation signal (refund / alert / paid). Actual: silently ignored.
      expect(result[:updated]).to be(true)
    end
  end

  # =====================================================================
  describe 'Jobs wiring' do
    it 'bin/bot starts the InvoiceExpirer (otherwise unpaid orders stay active forever)' do
      expect(File.read(File.expand_path('../../bin/bot', __dir__))).to include('InvoiceExpirer')
    end

    it 'expired orders end in EXPIRED status and the client gets a message' do
      order = make_order
      order.this.update(created_at: Time.now.utc - 3600)
      allow_any_instance_of(MWallet::Client).to receive(:cancel_invoice).and_return({})
      CoffeeBot::Jobs::InvoiceExpirer.new.run_once
      expect(order.refresh.status).to eq(OrderStatus::EXPIRED)
      expect(api.of(:send_message).map { |m| m[:chat_id] }).to include(client_id)
    end
  end

  # =====================================================================
  describe 'Order lifecycle / cancellation' do
    it '/cancel does not cancel an already PAID order without a refund' do
      order = make_order(status: OrderStatus::PAID)
      dispatch(text_msg('/cancel'))
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it '/cancel does not cancel an order the barista is already preparing' do
      order = make_order(status: OrderStatus::IN_PROGRESS)
      order.update(assigned_to_barista_id: barista_id)
      dispatch(text_msg('/cancel'))
      expect(order.refresh.status).to eq(OrderStatus::IN_PROGRESS)
    end

    it 'double-tap on "✅ Да" creates exactly one order and shows no Ruby error to the user' do
      draft_with_latte
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
        .and_return({ 'data' => { 'invoice_id' => 'INV-DBL', 'paylink_url' => 'https://pay' } })
      dispatch(cb('confirm_yes'))
      dispatch(cb('confirm_yes'))
      expect(Order.where(telegram_user_id: client_id).count).to eq(1)
      expect(api.texts.join).not_to match(/undefined method|NoMethodError/)
    end

    it 'comment is truncated to the 200-char DB column limit' do
      d = draft_with_latte
      d.set_step('add_comment')
      dispatch(text_msg('x' * 500))
      expect(Draft.for_user(client_id).comment.length).to be <= 200
    end

    it 'sending a sticker/photo during the comment step does not crash' do
      d = draft_with_latte
      d.set_step('add_comment')
      err = dispatch_like_listen_loop(non_text_msg)
      expect(err).not_to be_a(StandardError)
    end

    it 'rejects checkout if an item became unavailable after it was put in the cart' do
      d = draft_with_latte
      latte.update(is_available: false)
      order = Order.create_from_draft(d, Client.create(telegram_user_id: client_id, first_name: 'A', orders_count: 0))
      expect(order).to be_nil
    end

    it 'uses the CURRENT price at checkout, not the price when added to cart' do
      d = draft_with_latte
      latte.update(sizes: { 'small' => 13_000, 'medium' => 99_000, 'large' => 19_000 })
      order = Order.create_from_draft(d, Client.create(telegram_user_id: client_id, first_name: 'A', orders_count: 0))
      expect(order.total_amount).to eq(99_000)
    end

    it 'crafted callback qty_<id>_0 must not put a zero-quantity line into the cart' do
      dispatch(cb("qty_#{croissant.id}_0"))
      items = Draft.for_user(client_id)&.items || []
      expect(items.all? { |i| i['qty'].positive? }).to be(true)
    end

    it 'crafted callback with huge quantity is capped' do
      dispatch(cb("qty_#{croissant.id}_99999"))
      expect(Draft.for_user(client_id).items.first['qty']).to be <= 20
    end

    it 'order items are never silently dropped when one line fails validation' do
      d = Draft.get_or_create(client_id)
      d.update_state('items' => [
        { 'menu_item_id' => latte.id, 'name' => 'Латте', 'unit_price' => 15_000, 'qty' => 1, 'line_total' => 15_000 },
        { 'menu_item_id' => croissant.id, 'name' => 'Круассан', 'unit_price' => 12_000, 'qty' => 0, 'line_total' => 0 }
      ])
      order = Order.create_from_draft(d, Client.create(telegram_user_id: client_id, first_name: 'A', orders_count: 0))
      expect(order.order_items.sum(&:line_total)).to eq(order.total_amount)
    end

    it 'quick reorder works' do
      order = make_order(status: OrderStatus::READY)
      err = dispatch_like_listen_loop(cb("reorder_#{order.id}"))
      expect(err).not_to be_a(StandardError)
    end
  end

  # =====================================================================
  describe 'Authorization (barista actions)' do
    it 'a non-barista cannot view the barista queue (leaks client names)' do
      make_order(status: OrderStatus::PAID, user_id: 5555)
      dispatch(cb('barista_queue', from: stranger_id))
      expect(api.texts.join).not_to include('Заказ #')
    end

    it 'a non-barista cannot claim a paid order via a crafted callback' do
      order = make_order(status: OrderStatus::PAID)
      dispatch(cb("barista_claim_#{order.id}", from: stranger_id))
      expect(order.refresh.status).to eq(OrderStatus::PAID)
    end

    it 'a client cannot claim and "complete" their own order' do
      order = make_order(status: OrderStatus::PAID)
      dispatch(cb("barista_claim_#{order.id}", from: client_id))
      dispatch(cb("barista_complete_#{order.id}", from: client_id))
      expect(order.refresh.status).not_to eq(OrderStatus::READY)
    end

    it 'barista cannot complete an order assigned to someone else' do
      order = make_order(status: OrderStatus::IN_PROGRESS)
      order.update(assigned_to_barista_id: 9999)
      dispatch(cb("barista_complete_#{order.id}", from: barista_id))
      expect(order.refresh.status).to eq(OrderStatus::IN_PROGRESS)
    end

    it 'two baristas claiming the same order: only one wins' do
      stub_const('CoffeeBot::Config::BARISTA_WHITELIST', [barista_id, 2003])
      order = make_order(status: OrderStatus::PAID)
      dispatch(cb("barista_claim_#{order.id}", from: barista_id))
      dispatch(cb("barista_claim_#{order.id}", from: 2003))
      expect(order.refresh.assigned_to_barista_id).to eq(barista_id)
    end
  end

  # =====================================================================
  describe 'UX / Telegram protocol' do
    it 'each callback query is answered at most once (Telegram rejects re-answers => toasts/alerts are lost)' do
      make_order(status: OrderStatus::PAID)
      dispatch_like_listen_loop(cb('start_order'))       # wants show_alert "already have active order"
      dispatch_like_listen_loop(cb('menu_orders'))
      dispatch_like_listen_loop(cb('skip_comment'))
      expect(api.calls.map(&:first)).not_to include(:answer_callback_query_rejected)
    end

    it 'the "active order" alert text actually reaches the user' do
      make_order(status: OrderStatus::PAID)
      dispatch_like_listen_loop(cb('start_order'))
      alerts = api.of(:answer_callback_query).select { |a| a[:text] }
      expect(alerts).not_to be_empty
    end

    it 'main menu "☕ Кофе" shows items for a menu created by MenuService.seed_menu' do
      MenuItem.dataset.delete
      CoffeeBot::Services::MenuService.seed_menu
      dispatch(cb('menu_coffee'))
      expect(api.of(:edit_message_text)).not_to be_empty
    end

    it 'main menu "➕ Добавки" matches the category name used in the data' do
      MenuItem.create(category: '🥛 Добавки', name: 'Сироп', price: 2000, currency: 'KGS', is_available: true) # as in db/development.sqlite3
      dispatch(cb('menu_addons'))
      expect(api.of(:edit_message_text)).not_to be_empty
    end

    it 'empty-cart text has a real line break, not a literal "\n"' do
      dispatch(cb('menu_cart'))
      expect(api.texts.join).not_to include('\n')
    end

    it 'unexpected errors are not shown verbatim to the user' do
      draft_with_latte
      allow_any_instance_of(MWallet::Client).to receive(:create_invoice)
        .and_raise(MWalletError::BusinessError.new('SID 12345 invalid hash for merchant', code: 42))
      dispatch(cb('confirm_yes'))
      expect(api.texts.join).not_to include('SID 12345')
    end

    it 'unknown text with no draft gets a hint instead of silence' do
      dispatch(text_msg('привет'))
      expect(api.of(:send_message)).not_to be_empty
    end

    it 'item not in any draft: addon toggle on stale message does not crash' do
      err = dispatch_like_listen_loop(cb("addon_#{latte.id}_#{croissant.id}"))
      expect(err).not_to be_a(StandardError)
    end

    it 'cart_remove with out-of-range index is a no-op' do
      draft_with_latte
      err = dispatch_like_listen_loop(cb('cart_remove_42'))
      expect(err).not_to be_a(StandardError)
      expect(Draft.for_user(client_id).items.size).to eq(1)
    end

    it 'callback for a deleted menu item does not crash' do
      err = dispatch_like_listen_loop(cb('item_999999'))
      expect(err).not_to be_a(StandardError)
    end
  end

  # =====================================================================
  describe 'Data integrity' do
    it 'order status transitions are logged with the correct "from" status' do
      order = make_order(status: OrderStatus::NEW)
      logged = nil
      allow(order).to receive(:log_info) { |_m, ctx| logged = ctx }
      order.transition_to!(OrderStatus::INVOICE_CREATED)
      expect(logged[:from]).to eq(OrderStatus::NEW)
    end

    it 'status column rejects values outside OrderStatus::ALL (dev DB already has lowercase "cancelled")' do
      order = make_order
      expect { order.this.update(status: 'cancelled') }.to raise_error(Sequel::DatabaseError)
    end
  end
end
