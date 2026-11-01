# frozen_string_literal: true

namespace :decidim_bih do
  namespace :goodwill do
    desc "Retired historical September rescale; refuses all execution"
    task :rescale, [:apply] do
      abort "The historical September rescale is retired. Use a reviewed source-specific correction manifest."
    end
  end
end
