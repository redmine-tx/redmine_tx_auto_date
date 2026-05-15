module RedmineTxAutoDate
  module Patches
    module IssueQueryPatch
      def self.included(base)
        base.class_eval do
          # Add columns to available columns
          add_available_column TimestampQueryColumn.new(:begin_time, 
            :sortable => "#{Issue.table_name}.begin_time",
            :default_order => 'desc', 
            :groupable => true)
          
          add_available_column TimestampQueryColumn.new(:end_time,
            :sortable => "#{Issue.table_name}.end_time", 
            :default_order => 'desc',
            :groupable => true)
          
          add_available_column TimestampQueryColumn.new(:confirm_time,
            :sortable => "#{Issue.table_name}.confirm_time",
            :default_order => 'desc', 
            :groupable => true)

          add_available_column QueryColumn.new(:worker,
            :sortable => lambda {User.fields_for_order_statement("workers")},
            :groupable => true)
            
          # Override the initialize_available_filters method
          alias_method :initialize_available_filters_without_tx_auto_date, :initialize_available_filters
          alias_method :initialize_available_filters, :initialize_available_filters_with_tx_auto_date
        end
      end

      def initialize_available_filters_with_tx_auto_date
        initialize_available_filters_without_tx_auto_date
        
        # Add date filters
        add_available_filter "begin_time", :type => :date_past
        add_available_filter "end_time", :type => :date_past  
        add_available_filter "confirm_time", :type => :date_past
        
        # Add worker filter (same as assigned_to_id for consistency)
        add_available_filter(
          "worker_id",
          :type => :list_optional_with_history, :values => lambda {assigned_to_values}
        )
      end
    end
  end
end

# Apply the patch
if (ActiveRecord::Base.connection.tables.include?('queries') rescue false) &&
   IssueQuery.included_modules.exclude?(RedmineTxAutoDate::Patches::IssueQueryPatch)
  IssueQuery.send(:include, RedmineTxAutoDate::Patches::IssueQueryPatch)
end