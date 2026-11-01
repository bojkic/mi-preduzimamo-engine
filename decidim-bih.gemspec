# frozen_string_literal: true

$LOAD_PATH.push File.expand_path("lib", __dir__)

require "decidim/bih/version"

Gem::Specification.new do |spec|
  spec.name = "decidim-bih"
  spec.version = Decidim::Bih::VERSION
  spec.authors = ["Lokalna fondacija Bijeljina"]
  spec.email = ["bojan@fondacijabijeljina.com"]
  spec.license = "AGPL-3.0-or-later"
  spec.homepage = "https://github.com/bojkic/mi-preduzimamo-engine"
  spec.summary = "Decidim customizations for the Bosnian market (NGOs and public institutions)."
  spec.description = "Shared Decidim engine holding Bosnian-market customizations: locales, " \
                     "theme base and view/module overrides reused across deployments."

  spec.required_ruby_version = ">= 3.4.12"

  spec.files = Dir[
    "{app,config,db,docs,lib,public,script}/**/*",
    "rails_test/**/*",
    "LICENSE-AGPLv3.txt",
    "COPYRIGHT.md",
    "CHANGELOG.md",
    "Rakefile",
    "README.md"
  ]
  spec.require_paths = ["lib"]

  spec.add_dependency "decidim-core", Decidim::Bih::COMPAT_DECIDIM_VERSION
  # Engine overrides and public workflows currently assume these Decidim modules
  # are present. Treat them as hard requirements until those features are
  # explicitly guarded behind host-configurable flags.
  spec.add_dependency "decidim-budgets", Decidim::Bih::COMPAT_DECIDIM_VERSION
  spec.add_dependency "decidim-forms", Decidim::Bih::COMPAT_DECIDIM_VERSION
  spec.add_dependency "decidim-meetings", Decidim::Bih::COMPAT_DECIDIM_VERSION
  spec.add_dependency "decidim-proposals", Decidim::Bih::COMPAT_DECIDIM_VERSION
  spec.add_dependency "decidim-verifications", Decidim::Bih::COMPAT_DECIDIM_VERSION
  # Used by the Infobip/Gemini HTTP clients and the Sistem 48 archive scraper.
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "nokogiri", "~> 1.0"
  # Parsing city open-data PDFs (waste schedule, budget, official gazette).
  spec.add_dependency "pdf-reader", "~> 2.0"
  # Direct runtime integrations used by engine services.
  spec.add_dependency "mini_magick", "~> 4.9"
  spec.add_dependency "redis", "~> 4.0"
  spec.add_dependency "rqrcode", "~> 2.0"

  spec.metadata["rubygems_mfa_required"] = "true"
end
