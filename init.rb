Redmine::Plugin.register :redmine_tx_auto_date do
  name 'Redmine Tx Auto Date plugin'
  author 'KiHyun Kang'
  description 'This is a plugin for Redmine'
  version '0.0.1'
  url 'http://example.com/path/to/plugin'
  author_url 'http://example.com/about'

  #requires_redmine_plugin :redmine_tx_0_base, :version_or_higher => '0.0.1'
  requires_redmine_plugin :redmine_tx_advanced_issue_status, :version_or_higher => '0.0.1'
  requires_redmine_plugin :redmine_tx_advanced_tracker, :version_or_higher => '0.0.1'

  settings default: { 
    'begin_ratio' => 10, 
    'end_ratio' => 70 
  }, partial: 'settings/tx_auto_date'
end

Rails.application.config.after_initialize do
  require_dependency File.expand_path('../lib/redmine_tx_auto_date_helper.rb', __FILE__)
  require_dependency File.expand_path('../lib/redmine_tx_auto_date/patches/issue_patch.rb', __FILE__)
  require_dependency File.expand_path('../lib/redmine_tx_auto_date/patches/issues_helper_patch.rb', __FILE__)

  TxBaseHelper.register_issue_query_columns do
    timestamp_column :begin_time, filter: :date_past
    timestamp_column :end_time, filter: :date_past
    timestamp_column :confirm_time, filter: :date_past

    column :worker, sortable: -> { User.fields_for_order_statement("workers") }

    filter :worker_id, type: :list_optional_with_history, values: -> { assigned_to_values }
  end
end