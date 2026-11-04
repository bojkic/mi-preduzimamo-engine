# frozen_string_literal: true

require "rake/testtask"
require "decidim/bih/version"

# Load the engine's rake tasks (e.g. decidim_bih:cyrillize) — rake does not
# auto-load lib/tasks, so the documented commands need this.
Dir.glob(File.join(__dir__, "lib", "tasks", "**", "*.rake")).each { |t| load t }

desc "Prints the gem version"
task :version do
  puts Decidim::Bih::VERSION
end

Rake::TestTask.new("test:ruby") do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

namespace :test do
  desc "Run the JavaScript unit tests under test/javascript with node --test"
  task :javascript do
    files = Dir.glob(File.join(__dir__, "test/javascript/**/*_test.{js,cjs}"))
    # The file list is expanded here rather than handed to node as a glob or
    # a directory: which of those a given node build accepts has moved
    # between releases, and an empty or misread argument fails as "no tests"
    # rather than as an error.
    if files.empty?
      puts "[decidim-bih] no test/javascript/**/*_test.{js,cjs} files — nothing to run"
    elsif system("node", "--version", out: File::NULL, err: File::NULL)
      sh("node", "--test", *files)
    else
      raise "node not found on PATH; JavaScript tests did not run"
    end
  end

  desc "Run Rails/Postgres integration tests in a disposable Decidim host"
  task :rails do
    runner = -> { sh "script/decidim_bih_rails_test" }
    if defined?(Bundler)
      Bundler.with_unbundled_env { runner.call }
    else
      runner.call
    end
  end
end

# Complete both independent suites so a Ruby failure does not hide JS failures.
desc "Run all Ruby and JavaScript tests and report every failing suite"
task :test do
  failures = []
  %w(test:ruby test:javascript).each do |name|
    Rake::Task[name].invoke
  rescue StandardError => e
    warn "#{name} failed: #{e.message}"
    failures << name
  end
  raise "Failed test suites: #{failures.join(", ")}" if failures.any?
end

task default: :test
