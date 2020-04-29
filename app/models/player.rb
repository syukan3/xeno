class Player < ApplicationRecord
  belongs_to :xeno
  has_many :cards

  belongs_to :hand_card, class_name: 'Card', foreign_key: 'hand_card_num'
  belongs_to :draw_card, class_name: 'Card', foreign_key: 'draw_card_num'
end
