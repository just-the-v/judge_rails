# frozen_string_literal: true

require_relative "lib/judge/version"

Gem::Specification.new do |spec|
  spec.name = "judge_rails"
  spec.version = Judge::VERSION
  spec.authors = ["Hugo V"]
  spec.summary = "Semantic judgments from TypeSafe Jev as self-maintaining ActiveRecord attributes"
  spec.description = "A composable Ruby client for TypeSafe's Jev model, plus an ActiveRecord " \
                     "layer that turns natural-language judgments into ordinary, indexable, " \
                     "self-maintaining model attributes."
  spec.homepage = "https://github.com/just-the-v/judge_rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "lib/**/*.tt", "lib/**/*.yml", "README.md", "ADVANCED.md", "BENCHMARK.md",
                   "LICENSE.txt", "CHANGELOG.md"] - ["lib/judge/batch.rb"]
  spec.require_paths = ["lib"]

  # `require "judge"` loads nothing below. These are what `require "judge/rails"` needs, and that is
  # the whole of the dependency list.
  spec.add_dependency "activerecord", ">= 7.2", "< 9"
  spec.add_dependency "activesupport", ">= 7.2", "< 9"
end
