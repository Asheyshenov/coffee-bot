# frozen_string_literal: true

# Every query on tenant-scoped models must run inside a tenant (a coffee shop).
# Forgetting to set it raises instead of silently mixing data of different shops.
# Cross-tenant code (webhook routing, platform tasks) uses ActsAsTenant.without_tenant.
ActsAsTenant.configure do |config|
  config.require_tenant = true
end
