# frozen_string_literal: true
require "test_helper"
require "active_record"
require "ransack"
require "decidim/bih/ransack_resource_bounds"

class RansackResourceBoundsTest < Minitest::Test
  Bounds = Decidim::Bih::RansackResourceBounds
  class TraversalReached < StandardError; end
  class AliasModel
    def self._ransack_aliases = {}
  end
  class ProbeContext < Ransack::Adapters::ActiveRecord::Context
    def ransackable_attribute?(*) = raise(TraversalReached)
  end

  def setup
    Bounds.install!
    @search = Ransack::Search.allocate
    @context = ProbeContext.allocate
    @context.instance_variable_set(:@klass, AliasModel)
    @context.instance_variable_set(:@base, :sentinel_parent)
  end

  def collapse(value)
    @search.send(:collapse_multiparameter_attributes!, value)
  end

  def long_key = (["part"] * 202).join("_")

  def test_repeated_installation_preserves_one_copy_of_each_guard
    mode = Bounds.mode_for(Gem.loaded_specs.fetch("ransack").version)
    2.times { assert_equal mode, Bounds.install! }
    expected_copies = mode == :backport ? 1 : 0
    assert_equal expected_copies, Ransack::Search.ancestors.count(Bounds::SearchBounds)
    assert_equal expected_copies, Ransack::Context.ancestors.count(Bounds::ContextBounds)
    assert_equal expected_copies, Ransack::Adapters::ActiveRecord::Context.ancestors.count(Bounds::ActiveRecordContextBounds)
  end

  def test_version_selection_does_not_mistake_affected_major_releases_for_patched_versions
    assert_equal :backport, Bounds.mode_for("4.2.1")
    %w(4.4.3 5.0.2 6.0.0).each { |v| assert_equal :upstream, Bounds.mode_for(v) }
    %w(4.2.2 4.4.2 5.0.0 5.0.1 7.0.0).each do |v|
      assert_raises(Bounds::UnsupportedVersion) { Bounds.mode_for(v) }
    end
  end

  def test_legitimate_multiparameter_values_keep_conversion_and_sixteen_position_boundary
    result = collapse("time(1i)" => "2040", "time(6i)" => "12", "time(16i)" => "9", "name_cont" => "Synthetic")
    assert_equal 16, result.fetch("time").length
    assert_equal 2040, result.fetch("time").first
    assert_equal 12, result.fetch("time")[5]
    assert_equal 9, result.fetch("time").last
    assert_equal "Synthetic", result.fetch("name_cont")
  end

  def test_invalid_positions_and_truncated_keys_are_discarded_without_large_allocations
    # Boundary17 is enough to detect removal of the allocation bound safely.
    ["time(0i)", "time(-1i)", "time(17i)", "time(bad)", "time("].each do |key|
      assert_empty collapse(key => "1"), key
    end
  end

  def test_scalar_collisions_do_not_overwrite_plain_values_or_raise
    assert_equal({ "time" => "operator value" }, collapse("time" => "operator value", "time(1i)" => "2040"))
  end

  def test_nested_hash_under_an_allowed_outer_filter_is_bounded_too
    result = collapse("search_text_cont" => { "time(17i)" => "1", "label" => "Synthetic" })
    assert_equal({ "search_text_cont" => { "label" => "Synthetic" } }, result)
  end

  def test_long_condition_and_association_paths_stop_before_model_traversal
    refute @context.attribute_method?(long_key)
    assert_equal [:sentinel_parent, nil], @context.send(:get_parent_and_attribute_name, long_key)
    assert_equal "", @context.association_path(long_key)
    assert_raises(TraversalReached) { @context.attribute_method?("name") }
  end

  def test_real_sort_nodes_refuse_long_names_for_string_and_hash_forms
    sorts = [Ransack::Nodes::Sort.extract(@context, "#{long_key} desc"),
             Ransack::Nodes::Sort.new(@context).build(name: long_key, dir: "asc")]
    sorts.each { |sort| refute sort.bound? }
  end
end
