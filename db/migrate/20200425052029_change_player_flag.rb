class ChangePlayerFlag < ActiveRecord::Migration[5.2]
  def change
    remove_column :players, :predict_flag
    remove_column :players, :defence_flag
    remove_column :players, :mannual_flag

    add_column :players, :predict_flag, :boolean, default: false
    add_column :players, :defence_flag, :boolean, default: false
    add_column :players, :mannual_flag, :boolean, default: false
    add_column :players, :playing_flag, :boolean, default: false
  end
end
