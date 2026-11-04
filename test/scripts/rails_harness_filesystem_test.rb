# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class RailsHarnessFilesystemTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  NAME = "decidim_bih_rails_test_20261103120000_1_2_3"

  def run_with_existing(kind, script: "decidim_bih_rails_test")
    Dir.mktmpdir("mi-harness-existing-") do |directory|
      name = script == "decidim_bih_clean_host_smoke" ? NAME.sub("rails_test", "clean_host") : NAME
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      %w(ruby bundle npm decidim).each do |name|
        path = File.join(bin, name)
        # Framework/Redis commands are fixtures here: only the real launcher's
        # early filesystem refusal and cleanup behavior are under test.
        File.write(path, "#!/bin/sh\nexit 0\n")
        File.chmod(0o700, path)
      end
      target = File.join(directory, kind == :app ? name : "npm-wrapper-#{name}")
      FileUtils.mkdir_p(target)
      sentinel = File.join(target, "preserve.txt")
      File.write(sentinel, "original bytes")
      env = { "PATH" => "#{bin}:/usr/bin:/bin", "HOME" => directory, "RBENV_ROOT" => File.join(directory, "no-rbenv"),
              "ENGINE_ROOT" => ROOT, "WORK_ROOT" => directory, "APP_NAME" => name,
              "DECIDIM_EXECUTABLE" => "/usr/bin/true", "REDIS_URL" => "redis://127.0.0.1:6380/0" }
      _stdout, stderr, status = Open3.capture3(env, "bash", File.join(ROOT, "script", script), unsetenv_others: true)
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

  def test_clean_host_preserves_preexisting_host_and_wrapper
    run_with_existing(:app, script: "decidim_bih_clean_host_smoke")
    run_with_existing(:wrapper, script: "decidim_bih_clean_host_smoke")
  end

  def test_clean_host_generator_cannot_inherit_callers_private_bundle
    Dir.mktmpdir("mi-clean-host-bundle-") do |directory|
      name = NAME.sub("rails_test", "clean_host")
      bin = File.join(directory, "bin")
      FileUtils.mkdir_p(bin)
      %w(ruby bundle npm).each do |name|
        path = File.join(bin, name)
        File.write(path, "#!/bin/sh\nexit 0\n")
        File.chmod(0o700, path)
      end
      generator = File.join(bin, "decidim")
      File.write(generator, <<~'SH')
        #!/bin/sh
        printf '%s\n' "${BUNDLE_GEMFILE-unset}" "${BUNDLE_APP_CONFIG-unset}" "${BUNDLE_FROZEN-unset}" "${BUNDLE_DEPLOYMENT-unset}" "${RUBYOPT-unset}" "${RUBYLIB-unset}" "${BUNDLE_IGNORE_CONFIG-unset}" > "$HARNESS_CAPTURE"
        exit 42
      SH
      File.chmod(0o700, generator)
      capture = File.join(directory, "generator-bundle.txt")
      env = { "PATH" => "#{bin}:/usr/bin:/bin", "HOME" => directory, "RBENV_ROOT" => File.join(directory, "no-rbenv"),
              "ENGINE_ROOT" => ROOT, "WORK_ROOT" => directory, "APP_NAME" => name,
              "REDIS_URL" => "redis://127.0.0.1:6380/0", "HARNESS_CAPTURE" => capture, "DECIDIM_EXECUTABLE" => generator,
              "BUNDLE_GEMFILE" => "/fixture/private/Gemfile", "BUNDLE_APP_CONFIG" => "/fixture/private/config",
              "BUNDLE_FROZEN" => "true", "BUNDLE_DEPLOYMENT" => "true", "RUBYOPT" => "-rbundler/setup", "RUBYLIB" => "/fixture/private/lib" }
      _stdout, stderr, status = Open3.capture3(env, "bash", File.join(ROOT, "script/decidim_bih_clean_host_smoke"), unsetenv_others: true)
      assert_equal 42, status.exitstatus, stderr
      assert_equal ["unset", File.join(directory, name, ".bundle"), "unset", "unset", "unset", "unset", "1"], File.readlines(capture, chomp: true)
    end
  end
end
