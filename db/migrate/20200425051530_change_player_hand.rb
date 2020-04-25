class ChangePlayerHand < ActiveRecord::Migration[5.2]
  def change
    remove_column :players, :xeno_id
    remove_column :players, :hand

    add_column :players, :xeno_id, :integer
    add_column :players, :hand_card_num, :integer
    add_column :players, :draw_card_num, :integer
  end
end
