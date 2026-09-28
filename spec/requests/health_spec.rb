# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Health check and request spec tenancy", type: :request do
  it "answers /up for load balancers" do
    get "/up"
    expect(response).to have_http_status(:ok)
  end

  it "keeps the example's tenant set in request specs" do
    get "/up"
    expect(make_order.tenant).to eq(ActsAsTenant.current_tenant)
  end
end
