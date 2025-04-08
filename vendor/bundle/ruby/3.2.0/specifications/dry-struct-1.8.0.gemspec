# -*- encoding: utf-8 -*-
# stub: dry-struct 1.8.0 ruby lib

Gem::Specification.new do |s|
  s.name = "dry-struct".freeze
  s.version = "1.8.0"

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "allowed_push_host" => "https://rubygems.org", "bug_tracker_uri" => "https://github.com/dry-rb/dry-struct/issues", "changelog_uri" => "https://github.com/dry-rb/dry-struct/blob/main/CHANGELOG.md", "rubygems_mfa_required" => "true", "source_code_uri" => "https://github.com/dry-rb/dry-struct" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Piotr Solnica".freeze]
  s.date = "2025-03-09"
  s.description = "Typed structs and value objects".freeze
  s.email = ["piotr.solnica@gmail.com".freeze]
  s.homepage = "https://dry-rb.org/gems/dry-struct".freeze
  s.licenses = ["MIT".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 3.1.0".freeze)
  s.rubygems_version = "3.4.10".freeze
  s.summary = "Typed structs and value objects".freeze

  s.installed_by_version = "3.4.10" if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<dry-core>.freeze, ["~> 1.1"])
  s.add_runtime_dependency(%q<dry-types>.freeze, ["~> 1.8", ">= 1.8.2"])
  s.add_runtime_dependency(%q<ice_nine>.freeze, ["~> 0.11"])
  s.add_runtime_dependency(%q<zeitwerk>.freeze, ["~> 2.6"])
end
