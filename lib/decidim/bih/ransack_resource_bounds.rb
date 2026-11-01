# frozen_string_literal: true

# Security bounds adapted from Ransack v4.4.3, copyright (c) 2010 Ernie Miller.
# The upstream MIT grant is retained in licenses/ransack-MIT.txt.
# GHSA-vxc9-rm8f-p56j and GHSA-j3f8-w227-4hh8.
module Decidim
  module Bih
    # Decidim 0.31 pins the Ransack 4.2 line. Keep the parser guards local to
    # this engine instead of changing an installed/shared gem on the server.
    module RansackResourceBounds
      MAX_KEY_DEPTH = 200
      MULTIPARAMETER_POSITION_LIMIT = 16
      BACKPORT_VERSION = Gem::Version.new("4.2.1").freeze
      PATCHED_RANGES = [
        Gem::Requirement.new(">= 4.4.3", "< 5.0.0"),
        Gem::Requirement.new(">= 5.0.2", "< 6.0.0"),
        Gem::Requirement.new(">= 6.0.0", "< 7.0.0")
      ].freeze
      class UnsupportedVersion < StandardError; end

      module SearchBounds
        private

        def collapse_multiparameter_attributes!(attrs)
          attrs.keys.each do |k|
            if k.include?(::Ransack::Constants::LEFT_PARENTHESIS)
              real_attribute, position = k.split(/\(|\)/)
              value = attrs.delete(k)
              next if position.nil?

              cast = ::Ransack::Constants::A_S_I.include?(position.last) ? position.last : nil
              position = position.to_i - 1
              next if position < 0 || position >= MULTIPARAMETER_POSITION_LIMIT

              attrs[real_attribute] ||= []
              next unless attrs[real_attribute].is_a?(Array)

              attrs[real_attribute][position] =
              if cast
                if value.blank? && cast == ::Ransack::Constants::I
                  nil
                else
                  value.send("to_#{cast}")
                end
              else
                value
              end
            elsif Hash === attrs[k]
              collapse_multiparameter_attributes!(attrs[k])
            end
          end

          attrs
        end
      end

      module ContextBounds
        def key_within_depth_limit?(key)
          key.to_s.count("_") <= MAX_KEY_DEPTH
        end

        def association_path(str, base = @base)
          return "" unless key_within_depth_limit?(str)

          super
        end
      end

      module ActiveRecordContextBounds
        def attribute_method?(str, klass = @klass)
          return false unless key_within_depth_limit?(str)

          super
        end

        private

        def get_parent_and_attribute_name(str, parent = @base)
          return [parent, nil] unless key_within_depth_limit?(str)

          super
        end
      end

      def self.mode_for(version)
        version = Gem::Version.new(version.to_s)
        return :upstream if PATCHED_RANGES.any? { |range| range.satisfied_by?(version) }
        return :backport if version == BACKPORT_VERSION

        raise UnsupportedVersion, "Review Ransack resource bounds for version #{version} before booting this engine"
      end

      def self.install!
        require "ransack"
        return :upstream if mode_for(Gem.loaded_specs.fetch("ransack").version) == :upstream

        require "ransack/adapters/active_record/context"
        ::Ransack::Search.prepend(SearchBounds) unless ::Ransack::Search < SearchBounds
        ::Ransack::Context.prepend(ContextBounds) unless ::Ransack::Context < ContextBounds
        target = ::Ransack::Adapters::ActiveRecord::Context
        target.prepend(ActiveRecordContextBounds) unless target < ActiveRecordContextBounds
        :backport
      end
    end
  end
end
