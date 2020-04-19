class CreateCards < ActiveRecord::Migration[5.2]
  def change
    create_table :cards do |t|
      t.integer :xeno_id, null: false
      t.integer :card_num, null: false
      t.boolean :reincarnation_card, default: false
      t.integer :player_id

      t.timestamps
    end
  end
end
