# frozen_string_literal: true

require "rake"

# Running rake tasks in specs (type: :task):
#
#   result = run_task("tenants:create", "corner", "Corner Coffee")
#   expect(result).to be_success
#   expect(result.stdout).to include("created")
#
# Tasks are loaded once per process. abort / exit inside a task is captured as
# exit_status instead of ending the test run.
module InfraRakeHelpers
  TaskResult = Struct.new(:stdout, :stderr, :exit_status) do
    def success? = exit_status.nil? || exit_status.zero?
    def output = stdout + stderr
  end

  def self.load_tasks
    # "environment" comes from Rails' own tasks: present once anyone has loaded them
    Rails.application.load_tasks unless Rake::Task.task_defined?("environment")
  end

  def run_task(name, *args)
    InfraRakeHelpers.load_tasks
    task = Rake::Task[name]
    stdout = StringIO.new
    stderr = StringIO.new
    original_stdout, original_stderr = $stdout, $stderr
    exit_status = nil
    begin
      $stdout, $stderr = stdout, stderr
      task.reenable
      task.invoke(*args)
    rescue SystemExit => e
      exit_status = e.status
    ensure
      $stdout, $stderr = original_stdout, original_stderr
    end
    TaskResult.new(stdout.string, stderr.string, exit_status)
  end

  # Real rake runs have no current tenant; specs normally run inside one
  def without_current_tenant(&block)
    ActsAsTenant.with_tenant(nil, &block)
  end

  # Overrides ENV for the block (nil removes a variable) and restores it afterwards.
  # The local .env is loaded in tests too: override every variable a task reads.
  def with_env(vars)
    saved = vars.keys.to_h { |key| [ key, ENV.fetch(key, nil) ] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
    yield
  ensure
    saved&.each { |key, value| value.nil? ? ENV.delete(key) : ENV.store(key, value) }
  end
end

RSpec.configure do |config|
  config.include InfraRakeHelpers, type: :task
end
