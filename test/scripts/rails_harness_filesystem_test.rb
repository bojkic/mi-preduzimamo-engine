# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class RailsHarnessFilesystemTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  NAME = "decidim_bih_rails_test_20261103120000_1_2_3"

  def run_with_existing(kind)
    Dir.mktmpdir("mi-harness-existing-") do |directory|
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      %w(ruby bundle npm).each do |name|
        path = File.join(bin, name)
        # Framework/Redis commands are fixtures here: only the real launcher's
        # early filesystem refusal and cleanup behavior are under test.
        File.write(path, "#!/bin/sh\nexit 0\n")
        File.chmod(0o700, path)
      end
      target = File.join(directory, kind == :app ? NAME : "npm-wrapper-#{NAME}")
      FileUtils.mkdir_p(target)
      sentinel = File.join(target, "preserve.txt")
      File.write(sentinel, "original bytes")
      env = { "PATH" => "#{bin}:/usr/bin:/bin", "HOME" => directory, "RBENV_ROOT" => File.join(directory, "no-rbenv"),
              "ENGINE_ROOT" => ROOT, "WORK_ROOT" => directory, "APP_NAME" => NAME,
              "DECIDIM_EXECUTABLE" => "/usr/bin/true", "REDIS_URL" => "redis://127.0.0.1:6380/0" }
      _stdout, stderr, status = Open3.capture3(env, "bash", File.join(ROOT, "script/decidim_bih_rails_test"), unsetenv_others: true)
      assert_equal 64, status.exitstatus, stderr
      assert_includes stderr, "destination already exists"
      assert_equal "original bytes", File.read(sentinel)
    end
  end

  def test_preexisting_host_is_refused_and_preserved_even_on_exit_cleanup
    run_with_existing(:app)
  end

  def test_preexisting_npm_wrapper_is_refused_and_preserved_even_on_exit_cleanup
    run_with_existing(:wrapper)
  end
end
