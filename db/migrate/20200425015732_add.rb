class Add < ActiveRecord::Migration[5.2]
  def change
    add_column :players, :attend_flag, :datetime
  end
end
