class CreateXenos < ActiveRecord::Migration[5.2]
  def change
    create_table :xenos do |t|
      t.integer :status, null: false
      t.integer :num_of_player
      t.integer :now_order
      t.integer :winner_player_id

      t.timestamps
    end
  end
end
