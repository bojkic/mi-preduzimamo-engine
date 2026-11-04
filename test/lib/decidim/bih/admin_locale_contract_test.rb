# frozen_string_literal: true

require "minitest/autorun"
require "i18n"
require "json"

class AdminLocaleContractTest < Minitest::Test
  KEYS = JSON.parse(<<~JSON).freeze
    [
      "decidim.admin.models.participatory_process_step.fields.title",
      "decidim.admin.models.participatory_process_step.fields.start_date",
      "decidim.admin.models.participatory_process_step.fields.end_date",
      "decidim.admin.models.participatory_process_step.fields.actions",
      "decidim.admin.admin_terms_of_service.actions.refuse",
      "decidim.admin.admin_terms_of_service.actions.are_you_sure",
      "decidim.admin.admin_terms_of_service.actions.title",
      "decidim.admin.admin_terms_of_service.required_review.alert",
      "decidim.admin.admin_terms_of_service.required_review.callout",
      "decidim.admin.admin_terms_of_service.required_review.cta",
      "decidim.admin.admin_terms_of_service.accept.error",
      "decidim.admin.actions.activate",
      "decidim.admin.actions.add",
      "decidim.admin.actions.attachment.new",
      "decidim.admin.actions.attachment_collection.new",
      "decidim.admin.actions.attachment_collections",
      "decidim.admin.actions.attachments",
      "decidim.admin.actions.browse",
      "decidim.admin.actions.cancel",
      "decidim.admin.actions.configure",
      "decidim.admin.actions.confirm_delete_component",
      "decidim.admin.actions.confirm_delete_process",
      "decidim.admin.actions.confirm_destroy",
      "decidim.admin.actions.destroy",
      "decidim.admin.actions.duplicate",
      "decidim.admin.actions.edit",
      "decidim.admin.actions.export",
      "decidim.admin.actions.export_all",
      "decidim.admin.actions.export_selection",
      "decidim.admin.actions.import",
      "decidim.admin.actions.member.new",
      "decidim.admin.actions.menu_hidden",
      "decidim.admin.actions.moderate",
      "decidim.admin.actions.new_process_group",
      "decidim.admin.actions.new_process_step",
      "decidim.admin.actions.new_process_user_role",
      "decidim.admin.actions.newsletter.new",
      "decidim.admin.actions.per_page",
      "decidim.admin.actions.permissions",
      "decidim.admin.actions.preview",
      "decidim.admin.actions.publish",
      "decidim.admin.actions.resend_invitation",
      "decidim.admin.actions.restore",
      "decidim.admin.actions.see_process",
      "decidim.admin.actions.send_me_a_test_email",
      "decidim.admin.actions.share",
      "decidim.admin.actions.share_tokens",
      "decidim.admin.actions.soft_delete",
      "decidim.admin.actions.unpublish",
      "decidim.admin.actions.user.new",
      "decidim.admin.actions.view_deleted_components",
      "decidim.admin.participatory_process_steps.create.error",
      "decidim.admin.participatory_process_steps.create.success",
      "decidim.admin.participatory_process_steps.default_title",
      "decidim.admin.participatory_process_steps.destroy.error.active_step",
      "decidim.admin.participatory_process_steps.destroy.error.last_step",
      "decidim.admin.participatory_process_steps.destroy.success",
      "decidim.admin.participatory_process_steps.edit.update",
      "decidim.admin.participatory_process_steps.new.create",
      "decidim.admin.participatory_process_steps.ordering.error",
      "decidim.admin.participatory_process_steps.update.error",
      "decidim.admin.participatory_process_steps.update.success",
      "decidim.admin.participatory_processes.create.error",
      "decidim.admin.participatory_processes.create.success",
      "decidim.admin.participatory_processes.edit.update",
      "decidim.admin.participatory_processes.index.published",
      "decidim.admin.participatory_processes.index.unpublished",
      "decidim.admin.participatory_processes.update.error",
      "decidim.admin.participatory_processes.update.success",
      "decidim.participatory_processes.admin.participatory_process_steps.edit.title",
      "decidim.participatory_processes.admin.participatory_process_steps.index.title",
      "decidim.participatory_processes.admin.participatory_process_steps.new.title",
      "decidim.participatory_processes.admin.participatory_processes.form.slug_help_html",
      "decidim.participatory_processes.admin.participatory_process_duplicates.form.slug_help_html",
      "decidim.participatory_processes.admin.participatory_process_imports.form.slug_help_html",
      "editor.extensions.image.altLabel",
      "editor.extensions.image.nodeView.resizer.control.resize",
      "editor.extensions.image.nodeView.resizer.position.bottomLeft",
      "editor.extensions.image.nodeView.resizer.position.bottomRight",
      "editor.extensions.image.nodeView.resizer.position.topLeft",
      "editor.extensions.image.nodeView.resizer.position.topRight",
      "editor.extensions.image.uploadError",
      "editor.extensions.link.bubbleMenu.edit",
      "editor.extensions.link.bubbleMenu.remove",
      "editor.extensions.link.bubbleMenu.url",
      "editor.extensions.link.hrefLabel",
      "editor.extensions.link.targetLabel",
      "editor.extensions.link.targets.blank",
      "editor.extensions.link.targets.default",
      "editor.extensions.videoEmbed.titleLabel",
      "editor.extensions.videoEmbed.urlLabel",
      "editor.inputDialog.buttons.cancel",
      "editor.inputDialog.buttons.remove",
      "editor.inputDialog.buttons.save",
      "editor.inputDialog.close",
      "editor.toolbar.control.blockquote",
      "editor.toolbar.control.bold",
      "editor.toolbar.control.bulletList",
      "editor.toolbar.control.codeBlock",
      "editor.toolbar.control.common.eraseStyles",
      "editor.toolbar.control.hardBreak",
      "editor.toolbar.control.heading",
      "editor.toolbar.control.image",
      "editor.toolbar.control.indent.indent",
      "editor.toolbar.control.indent.outdent",
      "editor.toolbar.control.italic",
      "editor.toolbar.control.link",
      "editor.toolbar.control.orderedList",
      "editor.toolbar.control.underline",
      "editor.toolbar.control.videoEmbed",
      "editor.toolbar.textStyle.heading",
      "editor.toolbar.textStyle.normal",
      "editor.upload.uploadedFile",
      "decidim.admin.officializations.index.title",
      "decidim.admin.menu.components",
      "decidim.admin.menu.participants",
      "decidim.admin.menu.users",
      "decidim.admin.menu.share_tokens",
      "decidim.admin.menu.participatory_process_groups_submenu.landing_page",
      "decidim.admin.menu.participatory_processes_submenu.landing_page",
      "decidim.admin.menu.participatory_processes_submenu.attachments",
      "decidim.admin.menu.participatory_processes_submenu.attachment_collections",
      "decidim.admin.menu.participatory_processes_submenu.attachment_files",
      "decidim.admin.menu.participatory_processes_submenu.components",
      "decidim.admin.menu.participatory_processes_submenu.members",
      "decidim.admin.menu.participatory_processes_submenu.moderations",
      "decidim.admin.menu.participatory_processes_submenu.process_admins",
      "decidim.admin.participatory_process_publications.create.success",
      "decidim.admin.participatory_process_publications.create.error",
      "decidim.admin.participatory_process_publications.destroy.success",
      "decidim.admin.participatory_process_publications.destroy.error",
      "decidim.participatory_processes.admin.participatory_process_groups.form.title",
      "decidim.participatory_processes.admin.participatory_processes.edit.title",
      "decidim.participatory_processes.participatory_processes.description.title",
      "decidim.participatory_processes.participatory_processes.show.title",
      "decidim.admin.filters.search_label",
      "decidim.admin.filters.search_placeholder.title_cont",
      "decidim.accessibility.logo",
      "activerecord.models.decidim/participatory_process.one",
      "activerecord.models.decidim/participatory_process.other",
      "errors.messages.uppercase_only_letters_numbers"
    ]
  JSON

  def setup
    @backend = I18n.backend
    @paths = I18n.load_path
    @locales = I18n.available_locales
    I18n.backend = I18n::Backend::Simple.new
    I18n.available_locales = (@locales + [:en, :sr, :"sr-Cyrl", :bs, :hr]).uniq
    upstream = %w(decidim-core decidim-admin decidim-participatory_processes decidim-verifications devise).flat_map do |name|
      Dir[File.join(Gem::Specification.find_by_name(name).full_gem_path, "config/locales/*.{yml,yaml}")]
    end
    I18n.load_path = upstream + Dir[File.expand_path("../../../../config/locales/*.{yml,yaml}", __dir__)]
    I18n.backend.load_translations
  end

  def teardown
    I18n.backend = @backend
    I18n.load_path = @paths
    I18n.available_locales = @locales
  end

  def test_targeted_runtime_dictionary_is_native_and_preserves_interpolations_in_all_languages
    %w(sr sr-Cyrl bs hr).each do |locale|
      KEYS.each do |key|
        native = I18n.t(key, locale:, default: nil, fallback: false)
        english = I18n.t(key, locale: :en, default: nil, fallback: false)
        assert_kind_of String, native, "#{locale}: #{key}"
        refute_empty native, "#{locale}: #{key}"
        refute_equal english, native, "#{locale}: #{key}" unless %w(URL Link).include?(english)
        next unless english.is_a?(String)

        pattern = /%\{[^}]+\}|%[a-zA-Z_][a-zA-Z0-9_]*%/
        assert_equal english.scan(pattern).sort, native.scan(pattern).sort, "#{locale}: #{key} placeholders"
      end
    end
  end
end
