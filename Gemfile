# frozen_string_literal: true

source "https://rubygems.org"

require_relative "lib/decidim/bih/version"

# Resolve dependencies from the gemspec.
gemspec

# Dev/test tooling for the engine itself.
group :development, :test do
  gem "minitest", "~> 5.27"
  gem "decidim-dev", Decidim::Bih::COMPAT_DECIDIM_VERSION
end
