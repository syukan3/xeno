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
    @xeno = Xeno.first

    # 初期設定
    if @xeno.status == 0
      initial_setting(@xeno)
    end

    # 参加者募集 & メンバー変更
    if @xeno.status == 1
      player_setting(@xeno)
    end

    # ゲーム中
    if @xeno.status == 2

    end

    # ゲーム終了
    if @xeno.status == 3

    end


    events.each { |event|
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text

          if event.message['text'].eql?('@初期化')

            reset_xeno
            @xeno = Xeno.create(status: 0, now_order: 1)

            client.reply_message(event['replyToken'], initial_setting(@xeno))



          elsif event.message['text'].eql?('@テスト')
            response = client.get_profile('Ueb3521951ca7f9b01590e1cda06dbe66')
            contact = JSON.parse(response.body)
            user_name = contact['displayName']
            client.reply_message(event['replyToken'], sample(user_name))

          elsif event.message['text'].eql?('@サンプル')
            # client.reply_message(event['replyToken'], [ reset_setting, sample ])

            response = client.get_profile('Ueb3521951ca7f9b01590e1cda06dbe66')
            contact = JSON.parse(response.body)
            user_name = contact['displayName']
            player_ids = Player.pluck(:line_user_id)
            client.multicast(player_ids, sample(user_name))
            client.push_message(player_ids.first, reset_setting)


          elsif event.message['text'].eql?('@開始')
            client.reply_message(event['replyToken'], player_setting(@xeno))

          elsif ["@2人", "@3人", "@4人"].include?(event.message['text'])

            @xeno.num_of_player = event.message['text'].slice(1).to_i
            @xeno.status = 1
            @xeno.save
            client.reply_message(event['replyToken'], attending(@xeno))

          elsif event.message['text'].eql?('@参加')

            return if Player.all.length == @xeno.num_of_player

            Player.find_or_create_by(xeno_id: @xeno.id, line_user_id: event["source"]["userId"], user_name: 'myself')

            players = Player.all
            if players.length == @xeno.num_of_player

              # 順番決定
              set_order(players)

              # カードセット
              initial_set_card(@xeno)

              # ゲーム中
              @xeno.update(status: 2)

              player_ids = Player.pluck(:line_user_id)
              client.multicast(player_ids, display_settings(order_text(@xeno)))
            end

          else

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

  def display_settings(text)
    {
        "type": "text",
        "text": text
    }
  end

  def order_text(xeno)
    user_name = Player.order(:order).pluck(:user_name)
    text = "【順番】\n"
    text += user_name.join(" → \n")
    text += "\n#{user_name[xeno.now_order-1]} の番です。"
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
    card_list.each { |card_num| Card.create(xeno_id: xeno.id, card_num: card_num, reincarnation_card: false) }

    reincarnation_card = Card.all.shuffle.first
    reincarnation_card.update(reincarnation_card: true)
  end

  def draw_card(xeno)
    card = Card.where(xeno_id: xeno.id, reincarnation_card: false, player_id: nil).shuffle.first
    return card
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

  def reset_player
    Player.destroy_all
  end

  def reset_xeno
    Xeno.destroy_all
    Player.destroy_all
    Card.destroy_all
  end
end
