# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'QRPay Service' do
  describe 'Invoice idempotency' do
    let(:client) { create_test_client }
    let(:order) { create_test_order(client) }

    before do
      # Set up order with invoice
      order.update(
        status: OrderStatus::INVOICE_CREATED,
        invoice_id_provider: 'INV-12345',
        expires_at: Time.now.utc + 900
      )
    end

    it 'returns existing invoice if not expired' do
      # When invoice exists and not expired, should return existing
      service = QRPay::Service.new
      
      # Mock the client to track calls
      calls = []
      allow(service.client).to receive(:create_invoice) do
        calls << 1
        { 'invoiceId' => 'INV-NEW' }
      end

      # First call should not create new invoice
      result = service.create_invoice_for_order(order)
      
      expect(calls.length).to eq(0) # No API call made
      expect(result[:invoice_id]).to eq('INV-12345')
    end

    it 'creates new invoice if expired' do
      # Mark invoice as expired
      order.update(expires_at: Time.now.utc - 1)

      service = QRPay::Service.new
      
      # Mock API response
      allow(service.client).to receive(:create_invoice).and_return(
        'invoiceId' => 'INV-NEW',
        'qrUrl' => 'https://qr.example.com/new'
      )

      result = service.create_invoice_for_order(order)
      
      expect(result[:invoice_id]).to eq('INV-NEW')
    end
  end

  describe 'Status mapping' do
    it 'maps PAID status correctly' do
      expect(QRPay::StatusMapper.map_from_provider('PAID')).to eq(:paid)
      expect(QRPay::StatusMapper.map_from_provider('COMPLETED')).to eq(:paid)
      expect(QRPay::StatusMapper.map_from_provider('SUCCESS')).to eq(:paid)
    end

    it 'maps PENDING status correctly' do
      expect(QRPay::StatusMapper.map_from_provider('PENDING')).to eq(:pending)
      expect(QRPay::StatusMapper.map_from_provider('NEW')).to eq(:pending)
      expect(QRPay::StatusMapper.map_from_provider('WAITING')).to eq(:pending)
    end

    it 'maps CANCELLED status correctly' do
      expect(QRPay::StatusMapper.map_from_provider('CANCELLED')).to eq(:cancelled)
      expect(QRPay::StatusMapper.map_from_provider('CANCELED')).to eq(:cancelled)
    end

    it 'maps EXPIRED status correctly' do
      expect(QRPay::StatusMapper.map_from_provider('EXPIRED')).to eq(:expired)
      expect(QRPay::StatusMapper.map_from_provider('TIMEOUT')).to eq(:expired)
    end

    it 'returns :unknown for unrecognized status' do
      expect(QRPay::StatusMapper.map_from_provider('WEIRD')).to eq(:unknown)
      expect(QRPay::StatusMapper.map_from_provider(nil)).to eq(:unknown)
    end
  end

  describe 'Signature verification' do
    it 'signs and verifies payload' do
      signer = QRPay::Signer.new('test_secret_key')
      
      params = { 'amount' => 10000, 'orderId' => '123' }
      signature = signer.sign(params)
      
      expect(signer.verify(params, signature)).to be true
    end

    it 'rejects tampered payload' do
      signer = QRPay::Signer.new('test_secret_key')
      
      params = { 'amount' => 10000, 'orderId' => '123' }
      signature = signer.sign(params)
      
      tampered_params = { 'amount' => 20000, 'orderId' => '123' }
      
      expect(signer.verify(tampered_params, signature)).to be false
    end
  end
end
