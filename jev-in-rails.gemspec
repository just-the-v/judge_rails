# frozen_string_literal: true

require_relative "lib/jev/version"

Gem::Specification.new do |spec|
  spec.name = "jev-in-rails"
  spec.version = Jev::VERSION
  spec.authors = ["Hugo V"]
  spec.summary = "Semantic judgments from TypeSafe Jev as self-maintaining ActiveRecord attributes"
  spec.description = "A composable Ruby client for TypeSafe's Jev model, plus an ActiveRecord " \
                     "layer that turns natural-language judgments into ordinary, indexable, " \
                     "self-maintaining model attributes."
  spec.homepage = "https://github.com/beeleethebee/jev-in-rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "lib/**/*.tt", "README.md", "LICENSE.txt", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
end
