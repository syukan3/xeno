class XenosController < ApplicationController

  require 'line/bot'

  protect_from_forgery :except => [:callback]

  def client
    @client ||= Line::Bot::Client.new { |config|
      # config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      # config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
      config.channel_secret = 'e1ce936b888795e5cec1289df5e7d8be'
      config.channel_token = '0YmIICZKIc9+xEgiE8XJXcmb8ZrT2hDtOW3QY0DEf98vIKdOMVESQG3hGWOHvW+YVQWyKnn932Ajv5K39YeeKpRIAqwxONCPKQdRihb/w1OEAj2L1W67UKYxfXoaqIu8HuSyYZj4uU5HkwWDrTIA9AdB04t89/1O/w1cDnyilFU='
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

    events.each { |event|
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text

          if event.message['text'].eql?('@初期化')

            reset_xeno
            @xeno = Xeno.create(status: 0, now_order: 1)

            client.reply_message(event['replyToken'], initial_setting(@xeno))

          end


          # 初期設定
          if @xeno.status == 0

            if event.message['text'].eql?('@開始')

              client.reply_message(event['replyToken'], player_setting(@xeno))

            elsif ["@2人", "@3人", "@4人"].include?(event.message['text'])

              @xeno.num_of_player = event.message['text'].slice(1).to_i
              @xeno.status = 1
              @xeno.save
              # TODO: botに参加している全員に送付したい
              client.reply_message(event['replyToken'], attending(@xeno))

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

                # 順番決定
                set_order(players)

                # カード初期化
                initial_set_card(@xeno)

                # カード配布
                distribute_cards(@xeno, players)

                # ゲーム中
                @xeno.update(status: 2, now_order: 1)

                # Player 全員に順番送信
                player_ids = Player.pluck(:line_user_id)
                client.multicast( player_ids, display_text( order_text(@xeno) ) )

                # 順番が1番目の人に手札とドローカード、選択肢を送信する
                first_player = Player.find_by(xeno_id: @xeno.id, order: @xeno.now_order)
                draw_card_num = drawing(@xeno, first_player).card_num

                client.push_message( first_player.line_user_id, [ display_text(my_turn(first_player, draw_card_num, card_ja)), select_card(first_player, draw_card_num, card_ja) ] )

                # 順番が1番目以外の人に手札カードを送信する
                other_players = Player.where(xeno_id: @xeno.id).where.not(order: @xeno.now_order)
                other_players.each do |player|
                  player_id = player.line_user_id
                  client.push_message( player_id, display_text( other_turn(player, card_ja) ) )
                end
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

                # カードを使うメソッドを実行
                # [ 使うカード, 使う相手 ]
                use_card(@xeno, now_player, event.message['text'].slice(1).to_i, event['replyToken'])

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
                when 5

                  if type == '@target'
                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)
                    drawing(@xeno, target_player)

                    client.multicast( player_ids, display_text( "#{now_player.user_name}さんが\n#{target_player.user_name}さんに\n【死神】5 を発動しました" ) )
                    client.push_message( target_player.line_user_id,
                                         display_text( "1枚引きました\n" + "(あなたの手札)\n" + card_ja[:"#{target_player.hand_card_num}"] + "\n" + card_ja[:"#{target_player.draw_card_num}"] )
                    )
                    client.push_message( now_player.line_user_id, hide_drop_select_text(@xeno, target_player) )

                  elsif type == '@select'

                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)
                    select_card_num = text[1] == 'up' ? target_player.hand_card_num : target_player.draw_card_num

                    # プレイヤーの手札を更新
                    my_hand = select_card_num == target_player.hand_card_num ? target_player.draw_card_num : target_player.hand_card_num
                    target_player.update(draw_card_num: nil, hand_card_num: my_hand)

                    # カードをフィールドに出す
                    card = Card.find_by(xeno_id: @xeno.id, card_num: select_card_num, player_id: target_player.id, field_flag: false)
                    card.update(field_flag: true)

                    # 死神の結果を公開
                    client.multicast( player_ids, display_text( now_player.user_name + "が\n" + "【死神】5 発動により\n" + target_player.user_name + "の\n" + card_ja[:"#{select_card_num}"] + "を1枚捨てました" ) )

                    # ステータス
                    @xeno.update(status: 2)

                    # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                    next_turn_preparing(@xeno)
                  end

                when 8
                  if type == '@target'
                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)
                    exchange_card(now_player, target_player)
                    client.multicast( player_ids, display_text( "#{now_player.user_name}さんが\n#{target_player.user_name}に\n【交換】を発動しました") )

                    client.multicast( [ target_player.line_user_id, now_player.line_user_id ],
                                         display_text( "(#{target_player.user_name}の手札)\n#{card_ja[:"#{target_player.hand_card_num}"]}\n\n(#{now_player.user_name}の手札)\n#{card_ja[:"#{now_player.hand_card_num}"]}" )
                                         )
                  end

                  # ステータス
                  @xeno.update(status: 2)

                  # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                  next_turn_preparing(@xeno)

                when 9
                  if type == '@target'
                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)
                    drawing(@xeno, target_player)
                    client.push_message( target_player.line_user_id,
                                         [
                                             display_text( "#{now_player.user_name}さんがあなたに\n【公開処刑】を発動しました"),
                                             display_text( "1枚引きました\n" + "(あなたの手札)\n" + card_ja[:"#{target_player.hand_card_num}"] + "\n" + card_ja[:"#{target_player.draw_card_num}"] )
                                         ]
                    )
                    client.multicast( player_ids, display_text( display_emperor(@xeno, target_player, card_ja) ) )
                    client.push_message( now_player.line_user_id, emperor_select_text(@xeno, target_player, card_ja) )

                  elsif type == '@select'

                    target_player = Player.find_by(xeno_id: @xeno.id, id: text[0].to_i)
                    select_card_num = text[1].to_i

                    # プレイヤーの手札を更新
                    my_hand = select_card_num == target_player.hand_card_num ? target_player.draw_card_num : target_player.hand_card_num
                    target_player.update(draw_card_num: nil, hand_card_num: my_hand)

                    # カードをフィールドに出す
                    card = Card.find_by(xeno_id: @xeno.id, card_num: select_card_num, player_id: target_player.id, field_flag: false)
                    card.update(field_flag: true)

                    # 公開処刑の結果を公開
                    client.multicast( player_ids, display_text( now_player.user_name + "は\n" + target_player.user_name + "の\n" + card_ja[:"#{card.card_num}"] + "\nを【公開処刑】しました" ) )

                    # ステータス
                    @xeno.update(status: 2)

                    # 順番を更新、次の人に手札とドローカード、選択肢を送信する
                    next_turn_preparing(@xeno)
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

              elsif event.message['text'].eql?('@プレイヤー変更')

              elsif event.message['text'].eql?('@人数変更')

              end

              # 参加中のプレイヤー以外は操作を禁止
              # TODO: メッセージを返すようにする
            else
              return
            end
          end
        end
      end
    }

    head :ok
  end

  private

  def sample(name)
    {
        "type": "template",
        "altText": "this is a confirm template",
        "template": {
            "type": "confirm",
            "text": "#{name}さん、テストメッセージは届いていますか？",
            "actions": [
                {
                    "type": "message",
                    "label": "Yes",
                    "text": "yes"
                },
                {
                    "type": "message",
                    "label": "No",
                    "text": "no"
                }
            ]
        }
    }
  end

  def reset_setting
    {
        "type": "text",
        "text": "設定を初期化しました"
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

  def select_card(first_player, draw_card_num, card_ja)
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
                    "label": card_ja[:"#{first_player.hand_card_num}"],
                    "text": "@#{first_player.hand_card_num}"
                },
                {
                    "type": "message",
                    "label": card_ja[:"#{draw_card_num}"],
                    "text": "@#{draw_card_num}"
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

  def status_text(xeno)
    players = Player.all
    player_ids = players.ids
    deck = []
    fields = []

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
      text += "(#{player.user_name} 捨て札)"
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
    # card_list=[9,9,9,9,9,9,9,9,9]
    card_list.each { |card_num| Card.create(xeno_id: xeno.id, card_num: card_num, reincarnation_card: false) }

    reincarnation_card = Card.all.shuffle.first
    reincarnation_card.update(reincarnation_card: true)
  end

  def distribute_cards(xeno, players)
    ActiveRecord::Base.transaction do
      players.each do |player|
        card = Card.where(xeno_id: xeno.id, reincarnation_card: false, player_id: nil).shuffle.first
        player.update(hand_card_num: card.card_num)
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
    num_of_player = xeno.num_of_player
    now_order = xeno.now_order
    if num_of_player == now_order
      return 1
    else
      return now_order + 1
    end
  end

  def drawing(xeno, player)
    # TODO: 山札が 0ではないか確認するメソッドを実行する
    card = Card.where(xeno_id: xeno.id, reincarnation_card: false, player_id: nil).shuffle.first
    card.update(player_id: player.id)
    player.update(draw_card_num: card.card_num)
    return card
  end

  def next_turn_preparing(xeno)
    # 順番を更新
    xeno.update(now_order: next_order(xeno))

    # 次の人に手札とドローカード、選択肢を送信する
    next_player = Player.find_by(xeno_id: xeno.id, order: xeno.now_order)
    draw_card_num = drawing(xeno, next_player).card_num
    client.push_message( next_player.line_user_id,
                         [ display_text(my_turn(next_player, draw_card_num, card_ja)), select_card(next_player, draw_card_num, card_ja) ] )
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
  def my_turn(player, draw, card_ja)
    text = "【あなたのターン】\n"
    text += "（手札）\n"
    text += card_ja[:"#{player.hand_card_num}"]
    text += "\n"
    text += card_ja[:"#{draw}"]
    return text
  end

  # 順番が1番目以外の人に手札カードを送信する
  def other_turn(player, card_ja)
    text = "（あなたの手札）\n"
    text += card_ja[:"#{player.hand_card_num}"]
    return text
  end

  def use_card(xeno, player, number, event_reply_token)
    # プレイヤーの手札を更新
    my_hand = number == player.hand_card_num ? player.draw_card_num : player.hand_card_num
    player.update(draw_card_num: nil, hand_card_num: my_hand)

    # カードをフィールドに出す
    card = Card.find_by(xeno_id: xeno.id, card_num: number, player_id: player.id, field_flag: false)
    card.update(field_flag: true)

    continue_flag = false
    #
    case number
    when 1
      revolution_1(xeno, player, event_reply_token)
    when 2
      detect_2(player)
      next_turn_preparing(xeno)
    when 3
      seeing_3(player)
      next_turn_preparing(xeno)
    when 4
      guard_4(player)
      next_turn_preparing(xeno)
    when 5
      hide_drop_5(xeno, player, event_reply_token)
    when 6
      battle_6(player)
      next_turn_preparing(xeno)
    when 7
      predict_7(player)
      next_turn_preparing(xeno)
    when 8
      exchange_8(xeno, player, event_reply_token)
    when 9
      emperor_9(xeno, player, event_reply_token)
    when 10
      hero_10(player)
      next_turn_preparing(xeno)
    end
  end

  def revolution_1(xeno, player, event_reply_token)
    cards = Card.where(xeno_id: xeno.id, field_flag: true, card_num: 1)
    if cards.length == 2
      emperor_9(xeno, player, event_reply_token)
    else
      next_turn_preparing(xeno)
    end
  end

  def detect_2(player)

  end

  def seeing_3(player)

  end

  def guard_4(player)
    player.update(defence_flag: true)
  end

  def hide_drop_5(xeno, player, event_reply_token)
    players = select_target_player(xeno, player)

    xeno.update(status: 3)
    client.reply_message( event_reply_token, select_target_text(xeno, players, 5) )
  end

  def battle_6(player)

  end

  def predict_7(player)
    player.update(predict_flag: true)
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

  def hero_10(player)

  end

  def select_target_player(xeno, player)
    players = nil

    if xeno.num_of_player == 2
      Player.where(xeno_id: xeno.id).each do |p|
        players = p if player.id != p.id
      end
    else
      players = Player.where(xeno_id: xeno.id).where.not(player_id: player.id)
    end

    return players
  end

  def select_target_text(xeno, players, card_num)
    actions = []
    if xeno.num_of_player != 2
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
                  "actions": [ actions.join(',') ]
              }
          }

      return json

    else
      action =
          {
              "type": "message",
              "label": players.user_name,
              "text": "@target_#{players.id}_#{card_num}"
          }
      actions.push(action)

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

  def exchange_card(now_player, target_player)
    now_player_card_num = now_player.hand_card_num
    target_player_card_num = target_player.hand_card_num

    now_player.update(hand_card_num: target_player_card_num)
    target_player.update(hand_card_num: now_player_card_num)
  end

  def display_emperor(xeno, target_player, card_ja)
    text =  display_text_hash[:"#{9}"] + "\n"
    text += "（#{target_player.user_name} さんの手札）\n"
    text += card_ja[:"#{target_player.hand_card_num}"] + "\n"
    text += card_ja[:"#{target_player.draw_card_num}"]
    return text
  end

  def emperor_select_text(xeno, target_player, card_ja)
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
                    "label": card_ja[:"#{target_player.hand_card_num}"],
                    "text": "@select_#{target_player.id}_#{target_player.hand_card_num}_9"
                },
                {
                    "type": "message",
                    "label": card_ja[:"#{target_player.draw_card_num}"],
                    "text": "@select_#{target_player.id}_#{target_player.draw_card_num}_9"
                }
            ]
        }
    }
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
