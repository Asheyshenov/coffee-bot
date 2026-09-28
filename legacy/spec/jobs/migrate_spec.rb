# frozen_string_literal: true

require_relative '../spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'

# bin/migrate is what applies migrations outside development (docker-compose "migrate" service)
RSpec.describe 'bin/migrate' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:latest_version) do
    Dir[File.join(root, 'db/migrations/*.rb')].map { |f| File.basename(f).to_i }.max
  end

  def run_migrate(database_url)
    env = { 'RACK_ENV' => 'production', 'DATABASE_URL' => database_url }
    Open3.capture2e(env, RbConfig.ruby, 'bin/migrate', chdir: root)
  end

  it 'migrates an empty production database to the latest version and can be re-run' do
    Dir.mktmpdir do |dir|
      url = "sqlite://#{File.join(dir, 'migrate_spec.sqlite3')}"

      2.times do
        output, status = run_migrate(url)
        expect(status).to be_success, output
      end

      db = Sequel.connect(url, keep_reference: false)
      begin
        expect(db[:schema_info].get(:version)).to eq(latest_version)
        expect(db.table_exists?(:orders)).to be(true)
      ensure
        db.disconnect
      end
    end
  end

  it 'exits non-zero when the database cannot be migrated' do
    _output, status = run_migrate('sqlite:///nonexistent-coffee-bot-dir/db.sqlite3')
    expect(status).not_to be_success
  end
end
