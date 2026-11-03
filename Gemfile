# frozen_string_literal: true

source "https://rubygems.org"

require_relative "lib/decidim/bih/version"

# Resolve dependencies from the gemspec.
gemspec

# Dev/test tooling, including locale and optional Sidekiq logger contracts.
group :development, :test do
  gem "decidim-dev", Decidim::Bih::COMPAT_DECIDIM_VERSION
  gem "decidim-participatory_processes", Decidim::Bih::COMPAT_DECIDIM_VERSION
  gem "minitest", "~> 5.27"
  gem "sidekiq", "~> 7.3"
end
