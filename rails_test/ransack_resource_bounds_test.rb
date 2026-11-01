# frozen_string_literal: true
require "test_helper"
require "capybara"
require "decidim/meetings/test/factories"
require "decidim/bih/ransack_resource_bounds"

class RansackResourceBoundsRailsTest < ActiveSupport::TestCase
  setup do
    @organization = create_organization
    @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
    @alpha = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Synthetic Alpha")
    @beta = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Synthetic Beta")
    @foreign = FactoryBot.create(:user, :confirmed, organization: create_organization, name: "Synthetic Alpha")
  end

  def search(params)
    @organization.users.ransack(params, auth_object: @admin)
  end

  def long_key = (["part"] * 202).join("_")

  test "engine boot selects the matching resource protection without duplicate ancestors" do
    bounds = Decidim::Bih::RansackResourceBounds
    mode = bounds.mode_for(Gem.loaded_specs.fetch("ransack").version)
    2.times { assert_equal mode, bounds.install! }
    expected_copies = mode == :backport ? 1 : 0
    assert_equal expected_copies, Ransack::Search.ancestors.count(bounds::SearchBounds)
  end

  test "ordinary predicate and compound search retain tenant scoped results and sorting" do
    assert_equal [@alpha.id], search(name_cont: "Synthetic Alpha").result.pluck(:id)
    result = search(name_or_email_cont: "Synthetic", s: "name desc").result
    assert_equal [@beta.id, @alpha.id], result.where(id: [@alpha.id, @beta.id]).pluck(:id)
    assert_not_includes result.pluck(:id), @foreign.id
  end

  test "long condition and sort names cannot hide the valid predicate or expand tenant scope" do
    query = search(long_key + "_eq" => "ignored", "name_cont" => "Synthetic Alpha", "s" => "#{long_key} desc")
    assert_equal [@alpha.id], query.result.pluck(:id)
    query = search("name_cont" => "Synthetic Alpha", "s" => { "0" => { "name" => long_key, "dir" => "asc" } })
    assert_equal [@alpha.id], query.result.pluck(:id)
  end

  test "advanced attribute names and nested multiparameter input remain bounded inside scoped queries" do
    query = search("c" => { "0" => { "a" => [long_key], "p" => "eq", "v" => ["ignored"] } }, "name_cont" => "Synthetic Alpha")
    assert_equal [@alpha.id], query.result.pluck(:id)
    nested = search("name_cont" => { "time(17i)" => "1" }).result.pluck(:id)
    assert_not_includes nested, @foreign.id
  end
end

class RansackCalendarNestedFilterTest < ActionDispatch::IntegrationTest
  test "anonymous component calendar accepts bounded invalid nested filter without parser failure" do
    organization = create_organization
    host! organization.host
    process = FactoryBot.create(:participatory_process, organization:)
    component = FactoryBot.create(:component, manifest_name: "meetings", participatory_space: process)
    title = organization.available_locales.index_with { "Synthetic calendar meeting" }
    FactoryBot.create(:meeting, :published, component:, title:, address: "Synthetic street", latitude: 0, longitude: 0)
    path = Decidim::EngineRouter.main_proxy(component).calendar_path

    # Decidim deliberately returns an empty body when there are no events.
    # Establish a real calendar before checking that malformed input preserves it.
    get path
    assert_response :success
    assert_includes response.body, "BEGIN:VCALENDAR"
    assert_includes response.body, "SUMMARY:Synthetic calendar meeting"

    get path, params: { filter: { search_text_cont: { "time(17i)" => "1" } } }
    assert_response :success
    assert_equal "type/calendar", response.media_type

    # An invalid predicate may match no events; Decidim renders that as an
    # empty calendar response. A later ordinary request must still export it.
    get path
    assert_response :success
    assert_includes response.body, "BEGIN:VCALENDAR"
    assert_includes response.body, "SUMMARY:Synthetic calendar meeting"
  end
end
