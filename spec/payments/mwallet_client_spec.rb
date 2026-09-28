# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe MWallet::Client do
  subject(:client) do
    described_class.new(base_url: 'https://mwallet.test', sid: '123', password: 'secret', version: 1005,
                        timeout: 1, retry_count: 0, test_mode: true)
  end

  def stub_post(response_body)
    sent = []
    allow_any_instance_of(Faraday::Connection).to receive(:post) do |_conn, _path, body|
      sent << body
      instance_double(Faraday::Response, success?: true, status: 200, body: response_body)
    end
    sent
  end

  it 'cancels with the case-sensitive "invoiceCancel" command (sandbox rejects "InvoiceCancel")' do
    sent = stub_post({ 'data' => { 'success' => true } })

    expect(client.cancel_invoice('550362450351')).to eq({ 'data' => { 'success' => true } })
    expect(sent.first).to include('cmd' => 'invoiceCancel', 'data' => { 'invoice_id' => '550362450351' })
    expect(sent.first['hash']).to be_a(String)
  end

  it 'raises a business error for "Команда не определена"' do
    stub_post({ 'data' => { 'error' => 2, 'desc' => 'Команда не определена' } })

    expect { client.cancel_invoice('1') }.to raise_error(MWalletError::BusinessError, 'Команда не определена')
  end

  it 'maps the sandbox status of a cancelled invoice ("canceled")' do
    expect(MWallet::StatusMapper.map_from_provider('canceled')).to eq(:cancelled)
  end
end
