# frozen_string_literal: true

# Base class for jobs that work on one coffee shop's data.
# The tenant is passed explicitly and set around perform, so every query inside
# is scoped (acts_as_tenant require_tenant). Never pass records of tenant-scoped
# models as arguments: GlobalID would look them up outside the tenant.
#
#   class SomeJob < TenantJob
#     def perform_in_tenant(order_id) ... end
#   end
#   SomeJob.perform_later(tenant.id, order.id)
#   SomeJob.enqueue_for(order, wait: 5.seconds) # tenant and id taken from the record
class TenantJob < ApplicationJob
  def self.enqueue_for(record, *args, **options)
    set(**options).perform_later(record.tenant_id, record.id, *args)
  end

  def perform(tenant_id, *args)
    tenant = ActsAsTenant.without_tenant { Tenant.find_by(id: tenant_id) }
    return AppLog.warn("#{self.class.name}: tenant not found, skipping", tenant_id: tenant_id) unless tenant

    ActsAsTenant.with_tenant(tenant) { perform_in_tenant(*args) }
  end

  def perform_in_tenant(*)
    raise NotImplementedError
  end
end
