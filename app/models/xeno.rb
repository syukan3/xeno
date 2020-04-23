class Xeno < ApplicationRecord
  has_many :cards

  # enum status: {
  #     pending:      0,  # 保留
  #     applying:     1,  # メンバー募集
  #     playing:      2,  # ゲーム中
  #     finish:       3   # ゲーム終了
  # }
end
