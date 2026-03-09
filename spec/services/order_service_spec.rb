# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Order calculations and lifecycle' do
  describe 'Order total calculation' do
    it 'calculates total from order items' do
      client = create_test_client
      order = create_test_order(client, amount: 0)

      # Add items
      OrderItem.create(order_id: order.id, item_name: 'Капучино', qty: 2, unit_price: 15_000, line_total: 30_000)
      OrderItem.create(order_id: order.id, item_name: 'Круассан', qty: 1, unit_price: 12_000, line_total: 12_000)

      # Calculate total
      total = OrderItem.where(order_id: order.id).sum(:line_total)
      
      expect(total).to eq(42_000) # 300 + 120 = 420 KGS
    end

    it 'formats total in KGS' do
      order = create_test_order(create_test_client, amount: 15_000)
      
      expect(order.formatted_total).to eq('150 KGS')
    end
  end

  describe 'Order status transitions' do
    it 'allows NEW -> INVOICE_CREATED' do
      order = create_test_order(create_test_client)
      
      expect(order.can_transition_to?(OrderStatus::INVOICE_CREATED)).to be true
    end

    it 'allows INVOICE_CREATED -> PAID' do
      order = create_test_order(create_test_client)
      order.update(status: OrderStatus::INVOICE_CREATED)
      
      expect(order.can_transition_to?(OrderStatus::PAID)).to be true
    end

    it 'allows PAID -> IN_PROGRESS' do
      order = create_test_order(create_test_client)
      order.update(status: OrderStatus::PAID)
      
      expect(order.can_transition_to?(OrderStatus::IN_PROGRESS)).to be true
    end

    it 'allows IN_PROGRESS -> READY' do
      order = create_test_order(create_test_client)
      order.update(status: OrderStatus::IN_PROGRESS)
      
      expect(order.can_transition_to?(OrderStatus::READY)).to be true
    end

    it 'forbids NEW -> READY directly' do
      order = create_test_order(create_test_client)
      
      expect(order.can_transition_to?(OrderStatus::READY)).to be false
    end

    it 'forbids transitions from terminal status' do
      order = create_test_order(create_test_client)
      order.update(status: OrderStatus::READY)
      
      expect(order.can_transition_to?(OrderStatus::IN_PROGRESS)).to be false
    end

    it 'raises error on invalid transition' do
      order = create_test_order(create_test_client)
      
      expect {
        order.transition_to!(OrderStatus::READY)
      }.to raise_error(InvalidStatusTransition)
    end
  end

  describe 'Order claim by barista' do
    it 'claims order atomically' do
      order = create_test_order(create_test_client)
      order.update(status: OrderStatus::PAID)
      
      result = order.claim_for_barista!(999_888_777)
      
      expect(result).to be true
      expect(order.reload.status).to eq(OrderStatus::IN_PROGRESS)
      expect(order.assigned_to_barista_id).to eq(999_888_777)
    end

    it 'prevents double claim' do
      order = create_test_order(create_test_client)
      order.update(status: OrderStatus::PAID)
      
      # First claim succeeds
      first_claim = order.claim_for_barista!(111)
      
      # Second claim fails
      second_claim = order.claim_for_barista!(222)
      
      expect(first_claim).to be true
      expect(second_claim).to be false
      expect(order.reload.assigned_to_barista_id).to eq(111)
    end

    it 'cannot claim non-PAID order' do
      order = create_test_order(create_test_client)
      order.update(status: OrderStatus::IN_PROGRESS)
      
      result = order.claim_for_barista!(111)
      
      expect(result).to be false
    end
  end
end
