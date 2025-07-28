class AddBeginEndToIssues < ActiveRecord::Migration[5.2]
    def up
      add_column :issues, :begin_time, :datetime
      add_column :issues, :confirm_time, :datetime
      add_column :issues, :end_time, :datetime
      add_column :issues, :worker_id, :integer
    end
  
    def down
      remove_column :issues, :begin_time
      remove_column :issues, :confirm_time
      remove_column :issues, :end_time
      remove_column :issues, :worker_id
    end
  end 
  
