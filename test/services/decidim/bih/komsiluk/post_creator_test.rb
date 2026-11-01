# frozen_string_literal: true

require "test_helper"
require "active_support/time"
require_relative "../../../../../app/services/decidim/bih/komsiluk/post_creator"

module Decidim
  module Bih
    module Komsiluk
      class PostCreatorTest < Minitest::Test
        Organization = Struct.new(:id, :host, keyword_init: true)
        User = Struct.new(:id, keyword_init: true) do
          def with_lock
            yield
          end
        end
        Area = Struct.new(:id, keyword_init: true)

        class PostRecord
          attr_reader :organization, :author, :komsiluk, :category, :title, :body, :save_calls
          attr_accessor :id

          def initialize(attributes, save_result:, next_id:)
            @organization = attributes.fetch(:organization)
            @author = attributes.fetch(:author)
            @komsiluk = attributes.fetch(:komsiluk)
            @category = attributes.fetch(:category)
            @title = attributes.fetch(:title)
            @body = attributes.fetch(:body)
            @save_result = save_result
            @next_id = next_id
            @save_calls = 0
          end

          def save
            @save_calls += 1
            self.id ||= @next_id if @save_result
            @save_result
          end

          def urgent?
            %w(lost_pet safety).include?(category)
          end
        end

        class PostModel
          class << self
            attr_reader :created_posts, :where_calls
            attr_accessor :daily_count, :next_save_result

            def reset!
              @created_posts = []
              @where_calls = []
              @daily_count = 0
              @next_id = 1001
              @next_save_result = true
            end

            def where(*args)
              @where_calls << args
              self
            end

            def count
              daily_count
            end

            def new(attributes)
              post = PostRecord.new(attributes, save_result: next_save_result, next_id: @next_id)
              @next_id += 1
              created_posts << post
              post
            end
          end
        end

        class AwardDispatch
          class << self
            attr_reader :awards
            attr_accessor :raise_on_award

            def reset!
              @awards = []
              @raise_on_award = nil
            end
          end

          def self.komsiluk_post_created(post, author:)
            awards << { post:, author: }
            raise raise_on_award if raise_on_award
          end
        end

        class NotificationService
          class << self
            attr_reader :calls
            attr_accessor :raise_on_call

            def reset!
              @calls = []
              @raise_on_call = nil
            end

            def publish!(post:)
              @calls << { post: }
              raise raise_on_call if raise_on_call
            end
          end
        end

        class LogRedactor
          def self.error_message(error)
            error.message
          end
        end

        class Logger
          attr_reader :errors

          def initialize
            @errors = []
          end

          def error(message)
            @errors << message
          end
        end

        class RailsShim
          Config = Struct.new(:force_ssl, keyword_init: true)
          Application = Struct.new(:config, keyword_init: true)

          class << self
            attr_reader :application, :logger

            def reset!(force_ssl:)
              @application = Application.new(config: Config.new(force_ssl:))
              @logger = Logger.new
            end
          end
        end

        class EngineShim
          class UrlHelpers
            class << self
              attr_reader :calls

              def reset!
                @calls = []
              end

              def komsiluk_board_index_url(host:, protocol:)
                @calls << { host:, protocol: }
                "#{protocol}://#{host}/biceriseno/komsiluk"
              end
            end
          end

          class Routes
            def url_helpers
              UrlHelpers
            end
          end

          class << self
            def reset!
              UrlHelpers.reset!
            end

            def routes
              @routes ||= Routes.new
            end
          end
        end

        def setup
          @organization = Organization.new(id: 7, host: "mi.example.test")
          @author = User.new(id: 42)
          @komsiluk = Area.new(id: 12)
          PostModel.reset!
          AwardDispatch.reset!
          NotificationService.reset!
        end

        def test_rate_limit_returns_rate_limited_without_creating_post
          PostModel.daily_count = PostCreator::DAILY_LIMIT

          result = with_collaborators do
            creator.call(category: "general", title: "Pozdrav", body: "Komsiluk poruka")
          end

          assert_equal :rate_limited, result.status
          assert_equal "Pozdrav", result.post.title
          assert_equal 0, result.post.save_calls
          assert_equal [result.post], PostModel.created_posts
          assert_empty AwardDispatch.awards
          assert_empty NotificationService.calls
        end

        def test_invalid_save_returns_invalid_post_without_award_or_notification
          PostModel.next_save_result = false

          result = with_collaborators do
            creator.call(category: "general", title: "Pozdrav", body: "Komsiluk poruka")
          end

          assert_equal :invalid, result.status
          assert_same PostModel.created_posts.first, result.post
          assert_equal 1, result.post.save_calls
          assert_empty AwardDispatch.awards
          assert_empty NotificationService.calls
        end

        def test_valid_non_urgent_post_awards_points_and_captures_publication
          result = with_collaborators do
            creator.call(category: "general", title: "Pozdrav", body: "Komsiluk poruka")
          end

          post = result.post

          assert_equal :created, result.status
          assert_equal [post], PostModel.created_posts
          assert_equal @organization, post.organization
          assert_equal @author, post.author
          assert_equal @komsiluk, post.komsiluk
          assert_equal "general", post.category
          assert_equal "Pozdrav", post.title
          assert_equal "Komsiluk poruka", post.body
          assert_equal(
            [{ post:, author: @author }],
            AwardDispatch.awards
          )
          assert_equal [{ post: }], NotificationService.calls
        end

        def test_all_categories_use_the_same_durable_publication_boundary
          %w(lost_pet safety activity general).each do |category|
            result = with_collaborators do
              creator.call(category:, title: "Notice", body: "Text")
            end
            assert_equal :created, result.status
            assert_equal result.post, NotificationService.calls.last[:post]
          end
        end

        def test_award_exception_is_logged_and_created_result_is_returned
          AwardDispatch.raise_on_award = RuntimeError.new("ledger down")

          result = with_collaborators do
            creator.call(category: "general", title: "Pozdrav", body: "Komsiluk poruka")
          end

          assert_equal :created, result.status
          assert_equal 1, AwardDispatch.awards.size
          assert_equal 1, NotificationService.calls.size
          assert_equal 1, RailsShim.logger.errors.size
          assert_includes RailsShim.logger.errors.first, "points award failed"
          assert_includes RailsShim.logger.errors.first, "ledger down"
        end

        def test_publication_capture_failure_propagates_to_roll_back_the_create_transaction
          NotificationService.raise_on_call = RuntimeError.new("publication storage down")
          error = assert_raises(RuntimeError) do
            with_collaborators { creator.call(category: "general", title: "Notice", body: "Text") }
          end
          assert_equal "publication storage down", error.message
          assert_empty AwardDispatch.awards
        end

        private

        def creator
          PostCreator.new(organization: @organization, author: @author, komsiluk: @komsiluk)
        end

        def with_collaborators(force_ssl: true, &)
          RailsShim.reset!(force_ssl:)
          EngineShim.reset!
          goodwill = Module.new
          goodwill.const_set(:AwardDispatch, AwardDispatch)

          with_constant(Object, :Rails, RailsShim) do
            with_constant(Decidim::Bih, :LogRedactor, LogRedactor) do
              with_constant(Decidim::Bih, :Engine, EngineShim) do
                with_constant(Decidim::Bih, :KomsilukPost, PostModel) do
                  with_constant(Decidim::Bih::Komsiluk, :NoticePublishing, NotificationService) do
                    with_constant(Decidim::Bih, :Goodwill, goodwill, &)
                  end
                end
              end
            end
          end
        end

        def with_constant(parent, name, value)
          old_defined = parent.const_defined?(name, false)
          old_value = parent.const_get(name, false) if old_defined
          parent.send(:remove_const, name) if old_defined
          parent.const_set(name, value)
          yield
        ensure
          parent.send(:remove_const, name) if parent.const_defined?(name, false)
          parent.const_set(name, old_value) if old_defined
        end
      end
    end
  end
end
