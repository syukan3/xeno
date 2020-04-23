class Card < ApplicationRecord
  belongs_to :xeno
  belongs_to :player, optional: true
end
