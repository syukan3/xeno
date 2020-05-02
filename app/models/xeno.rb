class Xeno < ApplicationRecord
  has_many :cards
  has_one :player


  # enum status: {
  #     pending:      0,  # 保留
  #     applying:     1,  # メンバー募集
  #     playing:      2,  # ゲーム中
#       continue:     3   # 継続
  #     finish:       4   # ゲーム終了
  # }
end
