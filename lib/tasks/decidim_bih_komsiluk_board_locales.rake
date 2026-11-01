# frozen_string_literal: true

require "yaml"
require "decidim/bih/transliterator"

namespace :decidim_bih do
  namespace :komsiluk_boards do
    desc "Generate dedicated Komšiluk board Cyrillic locales from maintained Serbian Latin sources"
    task :cyrillize do
      directory = File.expand_path("../../config/locales", __dir__)
      Dir[File.join(directory, "komsiluk_boards*.sr.yml")].each do |source|
        target = source.sub(/\.sr\.yml\z/, ".sr-Cyrl.yml")
        data = YAML.safe_load_file(source).fetch("sr")
        output = { "sr-Cyrl" => Decidim::Bih::Transliterator.deep(data) }
        File.write(target, "# Generated from #{File.basename(source)} by decidim_bih:komsiluk_boards:cyrillize. Do not edit.\n" + YAML.dump(output, line_width: -1))
      end
    end
  end
end
