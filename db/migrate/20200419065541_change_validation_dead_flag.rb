class ChangeValidationDeadFlag < ActiveRecord::Migration[5.2]
  def change
    remove_column :players, :dead_flag
    add_column :players, :dead_flag, :boolean, default: false
  end
end
