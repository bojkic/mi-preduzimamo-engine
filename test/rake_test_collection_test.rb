# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class RakeTestCollectionTest < Minitest::Test
  def test_ruby_failure_does_not_hide_javascript_failure
    program = <<~'RUBY'
      require "rake"
      load "Rakefile"
      %w(test:ruby test:javascript).each do |name|
        Rake::Task[name].clear
        Rake::Task[name].enhance { puts "ran #{name}"; raise "intentional fixture failure" }
      end
      Rake::Task[:test].invoke
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", program, chdir: File.expand_path("..", __dir__))
    refute status.success?
    assert_includes out, "ran test:ruby"
    assert_includes out, "ran test:javascript"
    assert_includes err, "Failed test suites: test:ruby, test:javascript"
  end
end
