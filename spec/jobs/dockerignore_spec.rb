# frozen_string_literal: true

require_relative '../spec_helper'
require 'pathname'
require 'strscan'

module DockerIgnoreSpec
  # Minimal port of Docker's .dockerignore matching (moby/patternmatcher):
  # patterns are relative to the context root, "*" and "?" never cross "/",
  # "**" spans directories, a path is excluded when it or one of its parent
  # directories matches, and the last matching rule wins ("!" re-includes).
  class Rules
    def initialize(content)
      @rules = content.each_line.filter_map do |line|
        next if line.start_with?('#')

        pattern = line.strip
        next if pattern.empty?

        exclusion = pattern.start_with?('!')
        pattern = pattern[1..].strip if exclusion
        pattern = Pathname.new(pattern).cleanpath.to_s.delete_prefix('/')
        [exclusion, compile(pattern)]
      end
    end

    def excluded?(path)
      dirs = File.dirname(path).split('/')
      parents = dirs == ['.'] ? [] : dirs.each_index.map { |i| dirs[0..i].join('/') }

      @rules.reduce(false) do |matched, (exclusion, regex)|
        next matched if exclusion != matched

        ([path] + parents).any? { |candidate| regex.match?(candidate) } ? !exclusion : matched
      end
    end

    private

    def compile(pattern)
      scanner = StringScanner.new(pattern)
      source = +''
      until scanner.eos?
        source << if scanner.scan(%r{\*\*/?})
                    scanner.eos? ? '.*' : '(.*/)?'
                  elsif scanner.scan(/\*/)
                    '[^/]*'
                  elsif scanner.scan(/\?/)
                    '[^/]'
                  elsif scanner.scan(/\\(.)/)
                    Regexp.escape(scanner[1])
                  else
                    Regexp.escape(scanner.getch)
                  end
      end
      Regexp.new("\\A#{source}\\z")
    end
  end
end

# The Docker build context must never contain local databases (real client data),
# secrets or host gems, but must keep everything the image runs.
RSpec.describe '.dockerignore' do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:rules) { DockerIgnoreSpec::Rules.new(File.read(File.join(root, '.dockerignore'))) }

  def project_files(*globs)
    Dir.chdir(root) { Dir.glob(globs, File::FNM_DOTMATCH).select { |f| File.file?(f) } }
  end

  describe 'the matcher port itself' do
    it 'matches from the context root only, like Docker' do
      docker = DockerIgnoreSpec::Rules.new("*.db\n")
      expect(docker.excluded?('coffee.db')).to be(true)
      expect(docker.excluded?('db/coffee.db')).to be(false) # the bug this spec guards against
    end
  end

  it 'excludes local databases in any directory, including their journal files' do
    %w[
      coffee.db db/coffee.db db/development.sqlite3 db/test.sqlite
      db/development.sqlite3-wal db/development.sqlite3-shm db/coffee.db-journal
      data/coffee.sqlite3
    ].each do |path|
      expect(rules.excluded?(path)).to be(true), "#{path} would be copied into the image"
    end
  end

  it 'excludes every database file that currently exists in the working tree' do
    databases = project_files('*', 'db/**/*', 'config/**/*', 'lib/**/*', 'bin/**/*')
                .grep(/\.(sqlite3?|db)(-[a-z]+)?\z/)

    databases.each do |path|
      expect(rules.excluded?(path)).to be(true), "#{path} would be copied into the image"
    end
  end

  it 'excludes secrets, host gems, VCS and tool data' do
    %w[
      .env .env.production config/.env
      vendor/bundle/ruby/3.2.0/gems/pg-1.5.9/lib/pg.rb .bundle/config
      .git/HEAD .claude/worktrees/x/db/coffee.db .kilo/worktrees/x/.env
      .DS_Store lib/.DS_Store tmp/diagnostic.rb log/bot.log lib/jobs/debug.log
      spec/spec_helper.rb
    ].each do |path|
      expect(rules.excluded?(path)).to be(true), "#{path} would be copied into the image"
    end
  end

  it 'keeps everything the image needs to run' do
    needed = %w[Gemfile Gemfile.lock .env.example db/schema.rb] +
             project_files('bin/*', 'config/**/*.rb', 'lib/**/*.rb', 'db/migrations/*.rb')
    expect(needed).to include('bin/migrate', 'lib/jobs/invoice_expirer.rb')

    needed.each do |path|
      expect(rules.excluded?(path)).to be(false), "#{path} would be missing from the image"
    end
  end
end
