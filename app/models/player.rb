class Player < ApplicationRecord
  belongs_to :xeno
  has_many :cards
end
