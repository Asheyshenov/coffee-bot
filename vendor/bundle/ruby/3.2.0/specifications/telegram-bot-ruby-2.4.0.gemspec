# -*- encoding: utf-8 -*-
# stub: telegram-bot-ruby 2.4.0 ruby lib

Gem::Specification.new do |s|
  s.name = "telegram-bot-ruby".freeze
  s.version = "2.4.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "rubygems_mfa_required" => "true" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Alexander Tipugin".freeze]
  s.bindir = "exe".freeze
  s.date = "2025-02-13"
  s.email = ["atipugin@gmail.com".freeze]
  s.homepage = "https://github.com/atipugin/telegram-bot".freeze
  s.required_ruby_version = Gem::Requirement.new(">= 2.7".freeze)
  s.rubygems_version = "3.4.10".freeze
  s.summary = "Ruby wrapper for Telegram's Bot API".freeze

  s.installed_by_version = "3.4.10" if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<dry-struct>.freeze, ["~> 1.6"])
  s.add_runtime_dependency(%q<faraday>.freeze, ["~> 2.0"])
  s.add_runtime_dependency(%q<faraday-multipart>.freeze, ["~> 1.0"])
  s.add_runtime_dependency(%q<zeitwerk>.freeze, ["~> 2.6"])
end
