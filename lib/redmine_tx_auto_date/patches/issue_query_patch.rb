module RedmineTxAutoDate
  module Patches
    module IssueQueryPatch
      def self.included(base)
        base.class_eval do
          extend TxBaseHelper::IssueQueryColumnHelper
          include TxBaseHelper::IssueQueryColumnHelper

          # Add columns to available columns
          add_issue_timestamp_column :begin_time
          add_issue_timestamp_column :end_time
          add_issue_timestamp_column :confirm_time
          add_issue_column :worker, sortable: lambda {User.fields_for_order_statement("workers")}

          # Override the initialize_available_filters method
          alias_method :initialize_available_filters_without_tx_auto_date, :initialize_available_filters
          alias_method :initialize_available_filters, :initialize_available_filters_with_tx_auto_date
        end
      end

      def initialize_available_filters_with_tx_auto_date
        initialize_available_filters_without_tx_auto_date

        # Add date filters
        add_issue_date_filter :begin_time
        add_issue_date_filter :end_time
        add_issue_date_filter :confirm_time

        # Add worker filter (same as assigned_to_id for consistency)
        add_issue_filter "worker_id",
          type: :list_optional_with_history,
          values: lambda {assigned_to_values}
      end
    end
  end
end

# Apply the patch
if (ActiveRecord::Base.connection.tables.include?('queries') rescue false) &&
   IssueQuery.included_modules.exclude?(RedmineTxAutoDate::Patches::IssueQueryPatch)
  IssueQuery.send(:include, RedmineTxAutoDate::Patches::IssueQueryPatch)
end