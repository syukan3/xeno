class XenosController < ApplicationController

  require 'line/bot'

  protect_from_forgery :except => [:callback]

  def client
    @client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
      # config.channel_secret = "7351c06566970cf7505464368ac7c502"
      # config.channel_token = "XYq4BqTXejAoNxs0W6D0ZEwd6sbCfpmyNAs9kIx4hn4z5nqjxa19ic0SsL+NuXErhH+DDleA5Lx6zqnR3Hox6o5xq/6ac5hqWBsYCX0wh6nEAeiotLpp6in7p3yB3jUt94ISc5Nryo2lBqfM/vzp/wdB04t89/1O/w1cDnyilFU="
    }
  end

  def callback
    body = request.body.read

    signature = request.env['HTTP_X_LINE_SIGNATURE']
    unless client.validate_signature(body, signature)
      head :bad_request
    end

    events = client.parse_events_from(body)

    # ゲーム作成
    Xeno.first_or_create(status: 0, now_order: 1) if Xeno.all.length == 0

    # ゲーム抽出
    # TODO: callback のステータスの中に @xeno.id を埋め込みをして、そこから .find(params[:id] をしたい
    @xeno = Xeno.first

    events.each do |event|
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text

          if event.message['text'].eql?('@初期化')

            reset_xeno
            @xeno = Xeno.create(status: 0, now_order: 1)

            client.reply_message(event['replyToken'], initial_setting(@xeno))

          elsif event.message['text'].eql?('@ステータス')
            players = Player.where(xeno_id: @xeno.id)
            player_ids = players.pluck(:line_user_id)

            client.multicast( player_ids, display_text( status_text(@xeno, players) ) )
          end

          # 初期設定
          if @xeno.status == 0

            if event.message['text'].eql?('@開始')

              client.reply_message(event['replyToken'], player_setting(@xeno))

            elsif ["@2人", "@3人", "@4人"].include?(event.message['text'])

              @xeno.num_of_player = event.message['text'].slice(1).to_i
              @xeno.status = 1
              @xeno.save

              player_ids = Player.pluck(:line_user_id)
              client.reply_message(event['replyToken'], attending(@xeno))
              # client.multicast(player_ids, attending(@xeno))

            end

          # 参加者募集 & メンバー変更
          elsif @xeno.status == 1


            if event.message['text'].eql?('@参加')

              # TODO: 参加できなかったプレイヤーにメッセージでお知らせしたい
              return if Player.all.length == @xeno.num_of_player


              response = client.get_profile(event["source"]["userId"])
              contact = JSON.parse(response.body)
              user_name = contact['displayName']

              # TODO: @xeno.id を必須入力じゃなくして、attendance_flag をなくして、参加イベントでPlayerを作成、@参加を送信することでxeno_idを格納する
              Player.find_or_create_by(xeno_id: @xeno.id, line_user_id: event["source"]["userId"], user_name: user_name)

              players = Player.where(xeno_id: @xeno.id)
              if players.length == @xeno.num_of_player
                start_xeno(@xeno, players)
              end

            end

          # ゲーム中
          elsif @xeno.status == 2

            players = Player.where(xeno_id: @xeno.id)
            player_ids = players.pluck(:line_user_id)

            # 参加中のプレイヤーのみ
            if player_ids.include?(event["source"]["userId"])

              # ステータス表示

              # そのターンの人だけがゲーム操作可能
              now_player = Player.find_by(xeno_id: @xeno.id, order: @xeno.now_order)
              if now_player.line_user_id == event["source"]["userId"]

                use_card_id = event.message['text'].split("@")[1].to_i
                if Card.find(use_card_id).card_num == 10
                  client.reply_message(event['replyToken'],
                                       [
                                           display_text(card_ja[:"10"] + "\nは使用できません\n再度使用するカードを選択してください"),
                                           select_card(now_player, card_ja)
                                       ]
                  )
                  return
                else
                  use_card(@xeno, now_player, use_card_id, event['replyToken'])
                end
                # カードの効果


                # 勝敗判定
                # dead_flag が false のプレイヤーが1人ならゲーム終了 @xeno.update(status: 2)
                # それ以外なら、次のターンを実行



              # 今のターンの人以外は操作禁止
              # TODO: メッセージを返すようにする
              else
                return
              end
            # 参加中のプレイヤー以外は操作を禁止
            # TODO: メッセージを返すようにする
            else
              return
            end



          # 継続
          elsif @xeno.status == 3

            players = Player.where(xeno_id: @xeno.id)
            player_ids = players.pluck(:line_user_id)

            # 参加中のプレイヤーのみ
            if player_ids.include?(event["source"]["userId"])


              # ステータス表示

              # そのターンの人だけがゲーム操作可能
              now_player = Player.find_by(xeno_id: @xeno.id, order: @xeno.now_order)

              if now_player.line_user_id == event["source"]["userId"]

                type, *text, card_num = event.message['text'].split('_')

                case card_num.to_i
                when 2

                  if type == '@target'
                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)

                    if target_player_guard?(now_player, target_player, player_ids, 2)

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)

                    else

                      # フィールドに出ていないカード
                      not_field_cards = Card.where(xeno_id: @xeno.id, field_flag: false)

                      client.multicast( player_ids,
                                        [
                                            display_text( "#{now_player.user_name}さんが\n#{target_player.user_name}さんに\n#{card_ja[:"2"]}\nを発動しました" ),
                                            display_text( xeno_status(@xeno, players, not_field_cards) )
                                        ]
                      )
                      client.push_message( target_player.line_user_id, display_text( "(あなたの手札)\n" + card_ja[:"#{target_player.hand_card.card_num}"] ) )

                      client.push_message( now_player.line_user_id, seeing_select_text(@xeno, target_player, not_field_cards) )

                    end

                  elsif type == '@select'

                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)
                    select_card_num = text[1].to_i

                    messages = [
                        display_text( "#{now_player.user_name}は\n#{target_player.user_name}のカードを\n" + card_ja[:"#{select_card_num}"] + "\nと推測しました" )
                    # display_text( "正解です。\n#{target_player.user_name}\nは負けました" )
                    ]

                    if select_card_num == target_player.hand_card.card_num

                      if select_card_num == 10

                        messages << display_text( "正解です。\n#{target_player.user_name}\nは転生します" )

                        # 転生
                        check_reincarnation(@xeno, target_player, target_player.hand_card, messages)

                        # 結果を公開
                        client.multicast( player_ids, messages )

                        # 転生者に通知
                        client.push_message( target_player.line_user_id, display_text( "転生札は\n" + card_ja[:"#{target_player.hand_card.card_num}"] + "\nです" ) ) if select_card_num == 10

                        # ステータス
                        @xeno.update(status: 2)

                        # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                        next_turn_preparing(@xeno)

                      else

                        messages << display_text( "正解です。\n#{target_player.user_name}\nは負けました" )

                        # 結果を公開
                        client.multicast( player_ids, messages)

                        dead_process(@xeno, target_player)

                        # ステータス
                        @xeno.update(status: 2)

                        # ゲーム続行判定
                        continue_flag = judge_xeno(@xeno, player_ids)

                        # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                        next_turn_preparing(@xeno) if continue_flag

                      end

                    else

                      messages << display_text( "違います。" )
                      client.multicast( player_ids, messages )

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)
                    end

                  end

                when 3
                  if type == '@target'
                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)

                    if target_player_guard?(now_player, target_player, player_ids, 3)

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)

                    else

                      client.multicast( player_ids, display_text( "#{now_player.user_name}さんが\n#{target_player.user_name}に\n#{card_ja[:"3"]}\nを発動しました") )

                      client.push_message( now_player.line_user_id, display_text( "#{target_player.user_name}さんは\n" + card_ja[:"#{target_player.hand_card.card_num}"] + "\nを所有しています" ) )

                      client.push_message( target_player.line_user_id, display_text( "#{now_player.user_name}さんに\n所有しているカードを見せました" ) )

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)

                    end
                  end

                when 5

                  if type == '@target'
                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)


                    if target_player_guard?(now_player, target_player, player_ids, 5)

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)

                    else

                      card = drawing(@xeno, target_player)

                      if card

                        client.multicast( player_ids, display_text( "#{now_player.user_name}さんが\n#{target_player.user_name}さんに\n#{card_ja[:"5"]}\nを発動しました" ) )
                        client.push_message( target_player.line_user_id,
                                             display_text( "1枚引きました\n" + "(あなたの手札)\n" + card_ja[:"#{target_player.hand_card.card_num}"] + "\n" + card_ja[:"#{target_player.draw_card.card_num}"] )
                        )
                        client.push_message( now_player.line_user_id, hide_drop_select_text(@xeno, target_player) )

                      else
                        client.multicast( player_ids, display_text( "山札にカードがありません\n最終決戦です" ) )
                        last_battle(@xeno)
                      end
                    end

                  elsif type == '@select'

                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)
                    select_card_id = text[1] == 'up' ? target_player.hand_card_num : target_player.draw_card_num

                    # プレイヤーの手札を更新
                    my_hand_card_id = select_card_id == target_player.hand_card_num ? target_player.draw_card_num : target_player.hand_card_num
                    target_player.update(draw_card_num: nil, hand_card_num: my_hand_card_id)

                    # カードをフィールドに出す
                    select_card = Card.find(select_card_id)
                    select_card.update(field_flag: true)


                    messages = [
                        display_text( now_player.user_name + "が\n" + "【死神】5 発動により\n" + target_player.user_name + "の\n" + card_ja[:"#{select_card.card_num}"] + "を1枚捨てました" )
                    ]

                    # 転生するかどうかの確認
                    check_reincarnation(@xeno, target_player, select_card, messages)

                    # 死神の結果を公開
                    client.multicast( player_ids, messages )

                    # 転生者に通知
                    client.push_message( target_player.line_user_id, display_text( "転生札は\n" + card_ja[:"#{target_player.hand_card.card_num}"] + "\nです" ) ) if select_card.card_num == 10

                    # ステータス
                    @xeno.update(status: 2)

                    # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                    next_turn_preparing(@xeno)
                  end

                when 6
                  if type == '@target'
                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)

                    if target_player_guard?(now_player, target_player, player_ids, 6)

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)

                    else

                      client.multicast( player_ids, display_text( "#{now_player.user_name}さんが\n#{target_player.user_name}さんに\n#{card_ja[:"6"]}\nを発動しました" ) )

                      winner, loser = battle_on_doing(now_player, target_player)

                      if winner != loser

                        client.multicast( player_ids,
                                          [
                                              display_text( "勝者：#{winner.user_name}\n敗者：#{loser.user_name}\n\n#{loser.user_name}さんは\nゲーム終了です" ),
                                              display_text( "#{loser.user_name}さんは\n#{card_ja[:"#{loser.hand_card.card_num}"]}\nを持っていました" )
                                          ]
                        )

                        dead_process(@xeno, loser)

                        # ステータス
                        @xeno.update(status: 2)

                        # ゲーム続行判定
                        continue_flag = judge_xeno(@xeno, player_ids)

                        # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                        next_turn_preparing(@xeno) if continue_flag

                      else

                        client.multicast( player_ids,
                                              display_text( "#{card_ja[:"6"]}\n#{now_player.user_name}\n#{target_player.user_name}\n引き分けです" )
                        )

                        # ステータス
                        @xeno.update(status: 2)

                        # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                        next_turn_preparing(@xeno)

                      end
                    end
                  end

                when 7
                  if type == '@select'

                    select_card_id = text[1].to_i
                    select_card = Card.find(select_card_id)

                    # プレイヤーの手札を更新
                    now_player.update(draw_card_num: select_card_id)



                    # ステータス
                    @xeno.update(status: 2)

                    # 使用するカードを選択
                    client.reply_message(event['replyToken'],
                                         [
                                             display_text( card_ja[:"#{select_card.card_num}"] + "\nを選択しました" ),
                                             select_card(now_player, card_ja)
                                         ]
                    )

                  end

                when 8
                  if type == '@target'
                    target_player = Player.find(text[0].to_i)

                    if target_player_guard?(now_player, target_player, player_ids, 8)

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)

                    else

                      exchange_card(now_player, target_player)
                      client.multicast( player_ids, display_text( "#{now_player.user_name}さんが\n#{target_player.user_name}に\n#{card_ja[:"8"]}\nを発動しました") )

                      client.multicast( [ target_player.line_user_id, now_player.line_user_id ],
                                        display_text( "(#{target_player.user_name}の手札)\n#{card_ja[:"#{target_player.hand_card.card_num}"]}\n\n(#{now_player.user_name}の手札)\n#{card_ja[:"#{now_player.hand_card.card_num}"]}" )
                      )

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)

                    end
                  end

                when 9, 19
                  if type == '@target'
                    target_player = Player.find(text[0].to_i)

                    if target_player_guard?(now_player, target_player, player_ids, 9)

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)

                    else

                      card = drawing(@xeno, target_player)

                      if card

                        client.push_message( target_player.line_user_id,
                                             [
                                                 display_text( "#{now_player.user_name}さんがあなたに\n#{card_ja[:"9"]}\nを発動しました"),
                                                 display_text( "1枚引きました\n" + "(あなたの手札)\n" + card_ja[:"#{target_player.hand_card.card_num}"] + "\n" + card_ja[:"#{target_player.draw_card.card_num}"] )
                                             ]
                        )
                        client.multicast( player_ids, display_text( display_emperor(@xeno, target_player, card_ja) ) )
                        client.push_message( now_player.line_user_id, emperor_select_text(@xeno, target_player, card_ja, card_num.to_i) )

                      else
                        client.multicast( player_ids, display_text( "山札にカードがありません\n最終決戦です" ) )
                        last_battle(@xeno)
                      end
                    end

                  elsif type == '@select'

                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)
                    select_card = Card.find(text[1].to_i)

                    # プレイヤーの手札を更新
                    my_hand_card_id = select_card.id == target_player.hand_card_num ? target_player.draw_card_num : target_player.hand_card_num
                    target_player.update(draw_card_num: nil, hand_card_num: my_hand_card_id)

                    # カードをフィールドに出す
                    select_card.update(field_flag: true)

                    messages = [
                        display_text( now_player.user_name + "は\n" + target_player.user_name + "の\n" + card_ja[:"#{select_card.card_num}"] + "\nを【公開処刑】しました" )
                    ]

                    if select_card.card_num == 10

                      case card_num.to_i
                      when 9
                        dead_process(@xeno, target_player)

                        # 公開処刑の結果を公開
                        client.multicast( player_ids, messages )

                        # ステータス
                        @xeno.update(status: 2)

                        # ゲーム続行判定
                        continue_flag = judge_xeno(@xeno, player_ids)

                        # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                        next_turn_preparing(@xeno) if continue_flag

                      when 19

                        # 転生するかどうかの確認
                        check_reincarnation(@xeno, target_player, target_player.hand_card, messages)

                        # 公開処刑の結果を公開
                        client.multicast( player_ids, messages )

                        # ステータス
                        @xeno.update(status: 2)

                        # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                        next_turn_preparing(@xeno)

                      end

                    else

                      # 公開処刑の結果を公開
                      client.multicast( player_ids, messages )

                      # ステータス
                      @xeno.update(status: 2)

                      # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                      next_turn_preparing(@xeno)

                    end
                  end
                end

                # 今のターンの人以外は操作禁止
                # TODO: メッセージを返すようにする
              else
                return
              end
              # 参加中のプレイヤー以外は操作を禁止
              # TODO: メッセージを返すようにする
            else
              return
            end


          # ゲーム終了
          elsif @xeno.status == 4

            players = Player.where(xeno_id: @xeno.id)
            player_ids = players.pluck(:line_user_id)

            # 参加中のプレイヤーのみ
            if player_ids.include?(event["source"]["userId"])

              if event.message['text'].eql?('@次のゲーム')
                start_xeno(@xeno, players)
              elsif event.message['text'].eql?('@プレイヤー変更')

              elsif event.message['text'].eql?('@人数変更')

              elsif event.message['text'].eql?('@終了')

              end

              # 参加中のプレイヤー以外は操作を禁止
              # TODO: メッセージを返すようにする
            else
              return
            end
          end
        end
      end
    end

    head :ok
  end

  private

  def sample(name)
    {
        "type": "template",
        "altText": "this is a carousel template",
        "template": {
            "type": "carousel",
            "columns": [
                {
                    "title": display_text_hash[:"#{2}"],
                    "text": "相手が持っているカードを推測してください",
                    "actions": [
                        {
                            "type": "message",
                            "label": card_ja[:"1"],
                            "text": "@select_1_1_2"
                        },
                        {
                            "type": "message",
                            "label": card_ja[:"3"],
                            "text": "@select_1_3_2"
                        },
                        {
                            "type": "message",
                            "label": card_ja[:"4"],
                            "text": "@select_1_4_2"
                        }
                    ]
                },
                {
                    "title": display_text_hash[:"#{2}"],
                    "text": "相手が持っているカードを推測してください",
                    "actions": [
                        {
                            "type": "message",
                            "label": card_ja[:"5"],
                            "text": "@select_1_5_2"
                        },
                        {
                            "type": "message",
                            "label": card_ja[:"6"],
                            "text": "@select_1_6_2"
                        },
                        {
                            "type": "message",
                            "label": card_ja[:"7"],
                            "text": "@select_1_7_2"
                        }
                    ]
                },
                {
                    "title": display_text_hash[:"#{2}"],
                    "text": "相手が持っているカードを推測してください",
                    "actions": [
                        {
                            "type": "message",
                            "label": card_ja[:"8"],
                            "text": "@select_1_8_2"
                        },
                        {
                            "type": "message",
                            "label": card_ja[:"9"],
                            "text": "@select_1_9_2"
                        },
                        {
                            "type": "message",
                            "label": card_ja[:"10"],
                            "text": "@select_1_10_2"
                        }
                    ]
                }
            ]
        }
    }
  end

  def initial_setting(xeno)
    {
        "type": "template",
        "altText": "This is a buttons template",
        "template": {
            "type": "buttons",
            "title": "XENO スタートメニュー @#{xeno.id}",
            "text": "設定を初期化しました",
            "actions": [
                {
                    "type": "message",
                    "label": "ゲーム開始",
                    "text": "@開始"
                }
            ]
        }
    }
  end

  def player_setting(xeno)
    {
        "type": "template",
        "altText": "This is a buttons template",
        "template": {
            "type": "buttons",
            "title": "XENO 人数選択 @#{xeno.id}",
            "text": "選択してください",
            "actions": [
                {
                    "type": "message",
                    "label": "2人",
                    "text": "@2人"
                },
                {
                    "type": "message",
                    "label": "3人",
                    "text": "@3人"
                },
                {
                    "type": "message",
                    "label": "4人",
                    "text": "@4人"
                }
            ]
        }
    }
  end

  def attending(xeno)
    {
        "type": "template",
        "altText": "This is a buttons template",
        "template": {
            "type": "buttons",
            "title": "XENO 参加 @#{xeno.id}",
            "text": "ゲームをプレイする人は参加ボタンを押してください",
            "actions": [
                {
                    "type": "message",
                    "label": "参加",
                    "text": "@参加"
                }
            ]
        }
    }
  end

  def start_xeno(xeno, players)

    # 順番決定
    set_order(players)

    # カード初期化
    initial_set_card(xeno)

    # カード配布
    distribute_cards(xeno, players)

    # ゲーム中
    xeno.update(status: 2, now_order: 1)

    # Player 全員に順番送信
    player_ids = players.pluck(:line_user_id)
    client.multicast( player_ids, display_text( order_text(xeno) ) )

    # 順番が1番目の人に手札とドローカード、選択肢を送信する
    first_player = Player.find_by(xeno_id: xeno.id, order: xeno.now_order)
    drawing(xeno, first_player)

    client.push_message( first_player.line_user_id, [ display_text(my_turn(first_player, card_ja)), select_card(first_player, card_ja) ] )

    # 順番が1番目以外の人に手札カードを送信する
    other_players = Player.where(xeno_id: xeno.id).where.not(order: xeno.now_order)
    other_players.each do |player|
      player_id = player.line_user_id
      client.push_message( player_id, display_text( other_turn(player, card_ja) ) )
    end
  end

  def restart_setting(xeno)
    {
        "type": "template",
        "altText": "This is a buttons template",
        "template": {
            "type": "buttons",
            "title": "XENO 再スタートメニュー",
            "text": "再びゲームをはじめますか？\n【参加者引き継ぎ中】",
            "actions": [
                {
                    "type": "message",
                    "label": "次のゲーム",
                    "text": "@次のゲーム"
                },
                {
                    "type": "message",
                    "label": "プレイヤー変更",
                    "text": "@プレイヤー変更"
                },
                {
                    "type": "message",
                    "label": "人数変更",
                    "text": "@人数変更"
                },
                {
                    "type": "message",
                    "label": "終了",
                    "text": "@終了"
                }
            ]
        }
    }
  end

  def xeno_status(xeno, players, not_field_cards)

    # フィールドに出ているカード
    field_cards = Card.where(xeno_id: xeno.id, field_flag: true)

    text = ""

    # プレイヤーごとのフィールドのカード
    players.each do |player|
      player_cards = field_cards.where(player_id: player.id).order(updated_at: "ASC").pluck(:card_num)
      text += "(#{player.user_name}の捨て札)\n"
      text += player_cards.join(", ") + "\n"
    end

    not_field_cards_array = not_field_cards.order(card_num: "ASC").pluck(:card_num)

    text += "\n(フィールドに出ていないカード)\n"
    text += not_field_cards_array.join(", ") + "\n"

    return text

  end

  def select_card(player, card_ja)
    {
        "type": "template",
        "altText": "This is a buttons template",
        "template": {
            "type": "buttons",
            "title": "あなたのターン",
            "text": "使用するカードを選択してください",
            "actions": [
                {
                    "type": "message",
                    "label": card_ja[:"#{player.hand_card.card_num}"],
                    "text": "@#{player.hand_card.id}"
                },
                {
                    "type": "message",
                    "label": card_ja[:"#{player.draw_card.card_num}"],
                    "text": "@#{player.draw_card.id}"
                }
            ]
        }
    }
  end

  def display_text(text)
    {
        "type": "text",
        "text": text
    }
  end

  def order_text(xeno)
    user_name = Player.order(:order).pluck(:user_name)
    text = "【順番】\n"
    text += user_name.join(" → \n")
    text += "\n\n#{user_name[xeno.now_order-1]} の番です。"
    return text
  end

  def status_text(xeno, players)
    player_ids = players.pluck(:id)
    deck = []
    fields = [ [], [], [], [] ]

    Card.all.order(:updated_at).each do |card|
      case card.player_id
      when nil
        deck.push(card.card_num)
      when player_ids[0]
        fields[0].push(card.card_num)
      when player_ids[1]
        fields[1].push(card.card_num)
      when player_ids[2]
        fields[2].push(card.card_num)
      when player_ids[3]
        fields[3].push(card.card_num)
      end
    end

    text = '【ステータス】'
    text += '(残りのカード)'
    text += deck.join(', ')

    players.each_with_index do |player, index|
      text += "\n(#{player.user_name} 捨て札)\n"
      text += fields[index].join(', ')
    end

    return text
  end

  def finish_game(xeno, player)
    xeno.update(status: 3, winner_player_id: player.id)
  end

  def initial_set_card(xeno)
    return if xeno.status != 1

    Card.destroy_all

    card_list=[1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,10]
    card_list.each { |card_num| Card.create(xeno_id: xeno.id, card_num: card_num, reincarnation_card: false) }

    reincarnation_card = Card.all.shuffle.first
    reincarnation_card.update(reincarnation_card: true)
  end

  def distribute_cards(xeno, players)
    ActiveRecord::Base.transaction do
      players.each do |player|
        card = Card.where(xeno_id: xeno.id, reincarnation_card: false, player_id: nil).shuffle.first
        player.update(hand_card_num: card.id)
        card.update(player_id: player.id)
      end
    end
  end

  def throw_card(xeno, player, card_id)
    card = Card.find(card_id)
    card.update(player_id: player.id)
  end

  def set_order(players)

    order_array = []
    players.length.times { | num | order_array[num] = num+1 }
    order_array.shuffle!

    players.each do |p|
      p.order = order_array.shift
      p.save
    end

  end


  def next_order(xeno)

    players = Player.where(xeno_id: @xeno.id, dead_flag: false).order(order: 'asc')
    players_order_array = players.pluck(:order)

    now_order = xeno.now_order

    min = players_order_array.first
    max = players_order_array.last

    if now_order + 1 > max
      return players_order_array.first
    else

      if players_order_array.include?(now_order + 1)
        return now_order + 1
      elsif players_order_array.include?(now_order + 2)
        return now_order + 2
      elsif players_order_array.include?(now_order + 3)
        return now_order + 3
      end

    end
  end

  def drawing(xeno, player)

    deck = Card.where(xeno_id: xeno.id, reincarnation_card: false, player_id: nil)

    # 山札にカードがなければ、最終バトル
    if deck.length == 0
      if xeno.status == 2
        last_battle(xeno)
        return false
      elsif xeno.status == 3
        return false
      end
    end

    card = deck.shuffle.first
    card.update(player_id: player.id)
    player.update(draw_card_num: card.id)
    return card

  end

  def predict_drawing(xeno, next_player, deck)

    cards = deck.shuffle[0..2]

    actions = []

    cards.each do |card|
      action =
          {
              "type": "message",
              "label": card_ja[:"#{card.card_num}"],
              "text": "@select_#{next_player.id}_#{card.id}_7"
          }
      actions.push(action)
    end

    json =
        {
            "type": "template",
            "altText": "This is a buttons template",
            "template": {
                "type": "buttons",
                "title": display_text_hash[:"7"],
                "text": "手札に加えるカードを1枚選択してください",
                "actions": actions
            }
        }

    client.push_message( next_player.line_user_id, json )

  end

  def next_turn_preparing(xeno)
    # 山札の枚数を確認
    deck = Card.where(xeno_id: xeno.id, reincarnation_card: false, player_id: nil)

    # 順番を更新
    xeno.update(now_order: next_order(xeno))

    next_player = Player.find_by(xeno_id: xeno.id, order: xeno.now_order)

    # 山札は残り4枚です
    if deck.length == 4
      player_ids = Player.where(xeno_id: xeno.id).pluck(:line_user_id)
      client.multicast( player_ids, display_text("残りの山札は4枚です") )
    end

    # 守護の効果を外す
    if next_player.defence_flag == true
      next_player.update(defence_flag: false)
    end

    # 選択の効果を発動
    if next_player.predict_flag == true

      next_player.update(predict_flag: false)

      # 山札のカードが3枚以上あれば、3枚カードを引く
      if deck.length >= 3

        xeno.update(status: 3)
        predict_drawing(xeno, next_player, deck)

      # 山札のカードが1枚以上3枚未満あれば、通常通り1枚カードを引く
      elsif deck.length < 3

        card = drawing(xeno, next_player)

        if card
          client.push_message( next_player.line_user_id,
                               [ display_text(my_turn(next_player, card_ja)), select_card(next_player, card_ja) ] )
        end
      end

    else

      card = drawing(xeno, next_player)

      if card
        client.push_message( next_player.line_user_id,
                             [ display_text(my_turn(next_player, card_ja)), select_card(next_player, card_ja) ] )
      end
    end

  end



  def card_ja
    card_ja = {
        '1':  '【少年】1 (革命)',
        '2':  '【兵士】2 (捜査)',
        '3':  '【占師】3 (透視)',
        '4':  '【乙女】4 (守護)',
        '5':  '【死神】5 (疫病)',
        '6':  '【貴族】6 (対決)',
        '7':  '【賢者】7 (選択)',
        '8':  '【精霊】8 (交換)',
        '9':  '【皇帝】9 (公開処刑)',
        '10': '【英雄】10 (潜伏・転生)'
    }
    return card_ja
  end

  def display_text_hash
    display_text_hash = {
        '1': '○●捜査●○',
        '2': '○●捜査●○',
        '3': '○●透視●○',
        '4': '○●守護●○',
        '5': '○●疫病●○',
        '6': '○●対決●○',
        '7': '○●選択●○',
        '8': '○●交換●○',
        '9': '☆★公開処刑★☆',
        '10': '☆★潜伏・転生★☆'
    }
    return display_text_hash
  end

  # 順番が1番目の人に手札とドローカード、選択肢を送信する
  def my_turn(player, card_ja)
    text = "【あなたのターン】\n"
    text += "（手札）\n"
    text += card_ja[:"#{player.hand_card.card_num}"]
    text += "\n"
    text += card_ja[:"#{player.draw_card.card_num}"]
    return text
  end

  # 順番が1番目以外の人に手札カードを送信する
  def other_turn(player, card_ja)
    text = "（あなたの手札）\n"
    text += card_ja[:"#{player.hand_card.card_num}"]
    return text
  end

  def use_card(xeno, player, use_card_id, event_reply_token)
    # プレイヤーの手札を更新
    my_hand_card_id = use_card_id == player.hand_card.id ? player.draw_card.id : player.hand_card.id
    player.update(draw_card_num: nil, hand_card_num: my_hand_card_id)

    # カードをフィールドに出す
    card = Card.find(use_card_id)
    card.update(field_flag: true)

    continue_flag = false
    #
    case card.card_num
    when 1
      revolution_1(xeno, player, event_reply_token)
    when 2
      detect_2(xeno, player, event_reply_token)
    when 3
      seeing_3(xeno, player, event_reply_token)
    when 4
      guard_4(xeno, player, event_reply_token)
      next_turn_preparing(xeno)
    when 5
      hide_drop_5(xeno, player, event_reply_token)
    when 6
      battle_6(xeno, player, event_reply_token)
    when 7
      predict_7(xeno, player, event_reply_token)
      next_turn_preparing(xeno)
    when 8
      exchange_8(xeno, player, event_reply_token)
    when 9
      emperor_9(xeno, player, event_reply_token)
    when 10
      hero_10(player)
    end
  end

  def revolution_1(xeno, player, event_reply_token)
    cards = Card.where(xeno_id: xeno.id, field_flag: true, card_num: 1)
    player_ids = Player.where(xeno_id: xeno.id).pluck(:line_user_id)
    if cards.length == 2
      client.multicast( player_ids, display_text( "#{player.user_name}が\n" + card_ja[:"1"] + "\nの2枚目を発動しました。" ) )
      emperor_19(xeno, player, event_reply_token)
    else
      client.multicast( player_ids, display_text( "#{player.user_name}が\n" + card_ja[:"1"] + "\nの1枚目を発動しました。" ) )
      next_turn_preparing(xeno)
    end
  end

  def detect_2(xeno, player, event_reply_token)
    players = select_target_player(xeno, player)

    xeno.update(status: 3)
    client.reply_message( event_reply_token, select_target_text(xeno, players, 2) )
  end

  def seeing_3(xeno, player, event_reply_token)
    players = select_target_player(xeno, player)

    xeno.update(status: 3)
    client.reply_message( event_reply_token, select_target_text(xeno, players, 3) )
  end

  def guard_4(xeno, player, event_reply_token)
    player.update(defence_flag: true)

    players = Player.where(xeno_id: xeno.id)
    player_ids = players.pluck(:line_user_id)
    client.multicast( player_ids,
                         display_text("#{player.user_name}が\n#{card_ja[:"#{4}"]}\nを使用しました。\n次のターンまで#{player.user_name}への攻撃が無効化されます") )
  end

  def hide_drop_5(xeno, player, event_reply_token)
    players = select_target_player(xeno, player)

    xeno.update(status: 3)
    client.reply_message( event_reply_token, select_target_text(xeno, players, 5) )
  end

  def battle_6(xeno, player, event_reply_token)
    players = select_target_player(xeno, player)

    xeno.update(status: 3)
    client.reply_message( event_reply_token, select_target_text(xeno, players, 6) )
  end

  def predict_7(xeno, player, event_reply_token)
    player.update(predict_flag: true)
    players = Player.where(xeno_id: xeno.id)

    player_ids = players.pluck(:line_user_id)
    client.multicast( player_ids,
                         display_text("#{player.user_name}が\n#{card_ja[:"#{7}"]}\nを使用しました。\n次のターンカードを3枚ドローし、\n１枚を選択して手札に加えます") )
  end

  def exchange_8(xeno, player, event_reply_token)
    players = select_target_player(xeno, player)

    xeno.update(status: 3)
    client.reply_message( event_reply_token, select_target_text(xeno, players, 8) )
  end

  def emperor_9(xeno, player, event_reply_token)
    players = select_target_player(xeno, player)

    xeno.update(status: 3)
    client.reply_message( event_reply_token, select_target_text(xeno, players, 9) )
  end

  def emperor_19(xeno, player, event_reply_token)
    players = select_target_player(xeno, player)

    xeno.update(status: 3)
    client.reply_message( event_reply_token, select_target_text(xeno, players, 19) )
  end

  def hero_10(player)

  end

  def select_target_player(xeno, player)
    players = Player.where(xeno_id: xeno.id, dead_flag: false).where.not(id: player.id)
    return players
  end

  def select_target_text(xeno, players, card_num)
    actions = []
    players.each do |player|
      action =
          {
              "type": "message",
              "label": player.user_name,
              "text": "@target_#{player.id}_#{card_num}"
          }
      actions.push(action)
    end

    json =
        {
            "type": "template",
            "altText": "This is a buttons template",
            "template": {
                "type": "buttons",
                "title": display_text_hash[:"#{card_num}"],
                "text": "対象を選択してください",
                "actions": actions
            }
        }

    return json
  end

  def seeing_select_text(xeno, target_player, not_field_cards)
    actions = []
    not_field_cards_num = not_field_cards.order(:card_num).pluck(:card_num).uniq

    # フィールドに出ていないカード
    not_field_cards_num.each do |card_num|
      action =
          {
              "type": "message",
              "label": card_ja[:"#{card_num}"],
              "text": "@select_#{target_player.id}_#{card_num}_2"
          }
      actions.push(action)
    end

    json =
        {
            "type": "template",
            "altText": "this is a carousel template",
            "template": {
                "type": "carousel",
                "columns": [
                    {
                        "title": display_text_hash[:"#{2}"],
                        "text": "相手が持っているカードを推測してください",
                        "actions": [
                            {
                                "type": "message",
                                "label": card_ja[:"1"],
                                "text": "@select_#{target_player.id}_1_2"
                            },
                            {
                                "type": "message",
                                "label": card_ja[:"3"],
                                "text": "@select_#{target_player.id}_3_2"
                            },
                            {
                                "type": "message",
                                "label": card_ja[:"4"],
                                "text": "@select_#{target_player.id}_4_2"
                            }
                        ]
                    },
                    {
                        "title": display_text_hash[:"#{2}"],
                        "text": "相手が持っているカードを推測してください",
                        "actions": [
                            {
                                "type": "message",
                                "label": card_ja[:"5"],
                                "text": "@select_#{target_player.id}_5_2"
                            },
                            {
                                "type": "message",
                                "label": card_ja[:"6"],
                                "text": "@select_#{target_player.id}_6_2"
                            },
                            {
                                "type": "message",
                                "label": card_ja[:"7"],
                                "text": "@select_#{target_player.id}_7_2"
                            }
                        ]
                    },
                    {
                        "title": display_text_hash[:"#{2}"],
                        "text": "相手が持っているカードを推測してください",
                        "actions": [
                            {
                                "type": "message",
                                "label": card_ja[:"8"],
                                "text": "@select_#{target_player.id}_8_2"
                            },
                            {
                                "type": "message",
                                "label": card_ja[:"9"],
                                "text": "@select_#{target_player.id}_9_2"
                            },
                            {
                                "type": "message",
                                "label": card_ja[:"10"],
                                "text": "@select_#{target_player.id}_10_2"
                            }
                        ]
                    }
                ]
            }
        }

    return json
  end

  def target_player_guard?(now_player, target_player, player_ids, card_num)
    if target_player.defence_flag == true

      client.multicast( player_ids,
                        [
                            display_text( "#{now_player.user_name}さんが\n#{target_player.user_name}さんに\n#{card_ja[:"#{card_num}"]}\nを発動しました" ),
                            display_text( "#{target_player.user_name}が発動中の #{card_ja[:"4"]}\nにより無効化されました" )
                        ]
      )

      return true

    else
      return false
    end
  end

  def hide_drop_select_text(xeno, target_player)
    {
        "type": "template",
        "altText": "This is a buttons template",
        "template": {
            "type": "buttons",
            "title": display_text_hash[:"#{5}"],
            "text": "捨てるカードを選択してください",
            "actions": [
                {
                    "type": "message",
                    "label": "上",
                    "text": "@select_#{target_player.id}_up_5"
                },
                {
                    "type": "message",
                    "label": "下",
                    "text": "@select_#{target_player.id}_down_5"
                }
            ]
        }
    }
  end

  def battle_on_doing(now_player, target_player)
    now_player_card_num = now_player.hand_card.card_num
    target_player_card_num = target_player.hand_card.card_num

    if now_player_card_num > target_player_card_num
      winner = now_player
      loser = target_player
    elsif now_player_card_num < target_player_card_num
      winner = target_player
      loser = now_player
    else
      winner = 0
      loser = 0
    end

    client.multicast( [ target_player.line_user_id, now_player.line_user_id ],
                          display_text( "(#{target_player.user_name}の手札)\n#{card_ja[:"#{target_player.hand_card.card_num}"]}\n\n(#{now_player.user_name}の手札)\n#{card_ja[:"#{now_player.hand_card.card_num}"]}")
    )

    return [ winner, loser ]
  end

  def exchange_card(now_player, target_player)
    ActiveRecord::Base.transaction do
      now_hand_card_id = now_player.hand_card.id
      target_hand_card_id = target_player.hand_card.id

      # Player の card_id を更新
      now_player.update(hand_card_num: target_hand_card_id)
      target_player.update(hand_card_num: now_hand_card_id)

      # Card の player_id を更新
      Card.find(now_hand_card_id).update(player_id: target_player.id)
      Card.find(target_hand_card_id).update(player_id: now_player.id)
    end
  end

  def display_emperor(xeno, target_player, card_ja)
    text =  display_text_hash[:"#{9}"] + "\n"
    text += "（#{target_player.user_name} さんの手札）\n"
    text += card_ja[:"#{target_player.hand_card.card_num}"] + "\n"
    text += card_ja[:"#{target_player.draw_card.card_num}"]
    return text
  end

  def emperor_select_text(xeno, target_player, card_ja, card_num)
    {
        "type": "template",
        "altText": "This is a buttons template",
        "template": {
            "type": "buttons",
            "title": display_text_hash[:"#{9}"],
            "text": "処刑するカードを選択してください",
            "actions": [
                {
                    "type": "message",
                    "label": card_ja[:"#{target_player.hand_card.card_num}"],
                    "text": "@select_#{target_player.id}_#{target_player.hand_card_num}_#{card_num}"
                },
                {
                    "type": "message",
                    "label": card_ja[:"#{target_player.draw_card.card_num}"],
                    "text": "@select_#{target_player.id}_#{target_player.draw_card_num}_#{card_num}"
                }
            ]
        }
    }
  end

  # 転生するかどうかの確認 && 転生
  def check_reincarnation(xeno, target_player, select_card, messages)
    if select_card.card_num == 10
      # 転生札を抽出
      reincarnation_card = Card.find_by(xeno_id: xeno.id, reincarnation_card: true)
      # tatget_player の手札を捨てる
      target_player.hand_card.update(field_flag: true)
      # 転生札を自分の札として加える
      target_player.update(hand_card_num: reincarnation_card.id)
      reincarnation_card.update(player_id: target_player.id)
      # 天性したことをみんなに伝える
      messages << display_text( target_player.user_name + "\nは転生しました" )
      return messages
    end
  end

  def dead_process(xeno, loser)

    # カードをフィールドに出す
    card = Card.find(loser.hand_card_num)
    card.update(field_flag: true)

    # プレイヤーは負け
    loser.update(dead_flag: true, hand_card_num: nil, predict_flag: nil, defence_flag: nil)

  end

  def judge_xeno(xeno, player_ids)
    num_of_player = Xeno.find(xeno.id).num_of_player
    num_of_loser = Player.where(xeno_id: xeno.id, dead_flag: true).length

    if num_of_loser == num_of_player - 1
      winner = Player.find_by(xeno_id: xeno.id, dead_flag: false)

      xeno.update(status: 4, winner_player_id: winner.id)

      client.multicast( player_ids, [ display_text( "【ゲーム終了】\n勝者：#{winner.user_name}" ), restart_setting(xeno) ] )
      return false
    else
      return true
    end
  end

  def last_battle(xeno)
    players = Player.where(xeno_id: xeno.id)
    alive_players = players.where(dead_flag: false)
                        .sort { |a, b| b.hand_card.card_num <=> a.hand_card.card_num }

    xeno.update(status: 4, winner_player_id: alive_players.first.id)

    text = "【最終結果】\n"
    text += "★勝者：#{xeno.player.user_name}★\n\n"

    alive_players.each do |player|
      text += "（#{player.user_name}の手札）\n"
      text += card_ja[:"#{player.hand_card.card_num}"] + "\n"
    end

    dead_players = players.where(dead_flag: true)

    text += "\n途中敗退\n"
    dead_players.each do |player|
      text += "#{player.user_name}\n"
    end

    player_ids = players.pluck(:line_user_id)

    client.multicast( player_ids, [ display_text( text ), restart_setting(xeno) ] )

  end

  def reset_player
    Player.destroy_all
  end

  def reset_xeno
    Xeno.destroy_all
    Player.destroy_all
    Card.destroy_all
  end
end
