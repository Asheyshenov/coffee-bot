# frozen_string_literal: true

require_relative '../spec_helper'
require_relative '../../lib/bot/router'
require_relative 'support/router_spec_support'

RSpec.describe 'Router: barista authorization and callback answers' do
  include RouterSpecSupport

  def denial_alerts
    api.of(:answer_callback_query).select { |a| a[:text]&.include?('⛔') && a[:show_alert] }
  end

  describe 'barista actions' do
    %w[barista_queue barista_in_progress barista_menu].each do |data|
      it "denies #{data} to a non-barista with a visible alert and shows nothing" do
        make_order(status: OrderStatus::PAID, user_id: 5555)

        dispatch(cb(data, from: stranger_id))

        expect(denial_alerts.size).to eq(1)
        expect(api.of(:send_message)).to be_empty
        expect(api.of(:edit_message_text)).to be_empty
      end
    end

    it 'denies completing an order to a non-barista' do
      order = make_order(status: OrderStatus::IN_PROGRESS)
      order.update(assigned_to_barista_id: stranger_id)

      dispatch(cb("barista_complete_#{order.id}", from: stranger_id))

      expect(order.refresh.status).to eq(OrderStatus::IN_PROGRESS)
      expect(denial_alerts.size).to eq(1)
    end

    it 'denies /barista to a non-barista' do
      dispatch(text_msg('/barista', from: stranger_id))

      expect(api.of(:send_message).map { |m| m[:text] }).to eq([CoffeeBot::Bot::Router::BARISTA_ACCESS_DENIED])
    end

    it 'lets a barista see the queue' do
      make_order(status: OrderStatus::PAID, user_id: 5555)

      dispatch(cb('barista_queue', from: barista_id))

      expect(api.messages_to(barista_id).map { |m| m[:text] }.join).to include('Заказ #')
    end

    it 'barista_menu shows the barista panel to a barista' do
      dispatch(cb('barista_menu', from: barista_id))

      expect(api.of(:edit_message_text).last[:text]).to include('Панель баристы')
    end

    it 'lets a barista claim and then complete an order, notifying the client' do
      order = make_order(status: OrderStatus::PAID)

      dispatch(cb("barista_claim_#{order.id}", from: barista_id))
      expect(order.refresh.status).to eq(OrderStatus::IN_PROGRESS)
      expect(order.assigned_to_barista_id).to eq(barista_id)

      dispatch(cb("barista_complete_#{order.id}", from: barista_id))
      expect(order.refresh.status).to eq(OrderStatus::READY)

      client_texts = api.messages_to(client_id).map { |m| m[:text] }.join
      expect(client_texts).to include('Готовим ваш заказ')
      expect(client_texts).to include('готов')
    end

    it "shows a visible alert when a barista tries to complete someone else's order" do
      stub_const('CoffeeBot::Config::BARISTA_WHITELIST', [barista_id, 2003])
      order = make_order(status: OrderStatus::IN_PROGRESS)
      order.update(assigned_to_barista_id: 2003)

      dispatch(cb("barista_complete_#{order.id}", from: barista_id))

      expect(order.refresh.status).to eq(OrderStatus::IN_PROGRESS)
      answer = api.of(:answer_callback_query).first
      expect(answer[:text]).to include('не принадлежит вам')
      expect(answer[:show_alert]).to be(true)
    end

    it 'tells the second barista the order is already taken' do
      stub_const('CoffeeBot::Config::BARISTA_WHITELIST', [barista_id, 2003])
      order = make_order(status: OrderStatus::PAID)

      dispatch(cb("barista_claim_#{order.id}", from: barista_id))
      dispatch(cb("barista_claim_#{order.id}", from: 2003, id: 'q-second'))

      expect(order.refresh.assigned_to_barista_id).to eq(barista_id)
      second = api.of(:answer_callback_query).find { |a| a[:callback_query_id] == 'q-second' }
      expect(second[:text]).to include('другой бариста')
    end
  end

  describe 'answering callback queries' do
    it 'answers a plain callback exactly once' do
      dispatch(cb('menu_main', id: 'q-plain'))

      expect(api.of(:answer_callback_query)).to eq([{ callback_query_id: 'q-plain' }])
      expect(api.calls.map(&:first)).not_to include(:answer_callback_query_rejected)
    end

    it 'delivers a handler toast as the only answer' do
      dispatch(cb("addon_1_2", id: 'q-toast')) # no draft => "start the order first"

      expect(api.of(:answer_callback_query)).to eq([{ callback_query_id: 'q-toast', text: 'Начните заказ сначала' }])
      expect(api.calls.map(&:first)).not_to include(:answer_callback_query_rejected)
    end

    it 'still answers (once) when the handler raises' do
      allow(router).to receive(:handle_menu_main).and_raise(RuntimeError, 'boom')

      expect { dispatch(cb('menu_main', id: 'q-raise')) }.to raise_error(RuntimeError, 'boom')

      expect(api.of(:answer_callback_query)).to eq([{ callback_query_id: 'q-raise' }])
    end

    it 'does not raise or mask the handler result when Telegram rejects the answer' do
      allow(api).to receive(:answer_callback_query).and_raise(StandardError, 'query is too old')

      expect { dispatch(cb('menu_main')) }.not_to raise_error
      expect(api.of(:edit_message_text)).not_to be_empty
    end
  end
end
