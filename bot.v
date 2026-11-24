module voltlib

import json2
import net.http

// open_bot_chat opens a direct conversation using the signed-in user's session.
pub fn (client Client) open_bot_chat(username string) !Chat {
	name := username.trim_space().to_lower()
	if name.len < 5 || name.len > 32 || !name.ends_with('bot')
		|| name.bytes().any(!it.is_alnum() && it !in [`_`, `-`]) {
		return error('Invalid Volt bot username')
	}
	chat := client.request_json[Chat](.post, '/bots/${name}/chat', '')!
	return chat.with_client(client)
}

pub struct BotClient {
	token string @[skip]
pub:
	base_url string
}

// new_bot creates a client for the Bearer-token Bot API.
pub fn new_bot(token string, options ClientOptions) !BotClient {
	if token == '' || token.bytes().any(!it.is_alnum() && it !in [`_`, `-`, `.`, `~`, `+`, `/`,
		`=`]) {
		return error('Invalid Volt bot token')
	}
	origin := parse_volt_origin(options.base_url)!
	return BotClient{
		token:    token
		base_url: '${origin.scheme}://${origin.host}'
	}
}

pub fn (bot BotClient) str() string {
	return 'voltlib.BotClient(${bot.base_url})'
}

pub struct BotApiError {
	Error
pub:
	status_code int
	error_code  int
	description string
}

pub fn (err BotApiError) msg() string {
	return 'Volt Bot API HTTP ${err.status_code} — ${err.description}'
}

pub fn (err BotApiError) code() int {
	return if err.error_code > 0 { err.error_code } else { err.status_code }
}

struct BotResponse[T] {
	ok          bool
	result      ?T
	error_code  int
	description string
}

fn (bot BotClient) post[T](endpoint string, data string) !T {
	mut header := http.new_header(key: .authorization, value: 'Bearer ${bot.token}')
	response := fetch_volt_response(bot.base_url, .post, '/bot/' + endpoint, data, mut header)!
	success := response.status_code >= 200 && response.status_code < 300
	body := json2.decode[BotResponse[T]](response.body) or {
		if success {
			return error('Invalid Volt Bot API response for /bot/${endpoint}')
		}
		BotResponse[T]{}
	}
	if success && body.ok {
		return body.result or { return error('Missing result for /bot/${endpoint}') }
	}
	return BotApiError{
		status_code: response.status_code
		error_code:  body.error_code
		description: if body.description != '' {
			body.description
		} else {
			http.status_from_int(response.status_code).str()
		}
	}
}

pub struct BotUser {
pub:
	id         int
	username   string
	first_name string
	is_bot     bool
}

pub struct BotChat {
	bot BotClient @[skip]
pub:
	id         int
	type       string
	first_name string
	username   string
}

pub struct BotMessage {
pub:
	message_id          int
	date                i64
	sender              BotUser @[json: 'from']
	chat                BotChat
	text                string
	edit_date           i64
	reply_to_message_id int
	reply_markup        ?BotReplyMarkup
}

pub struct BotReplyMarkup {
pub:
	inline_keyboard [][]BotKeyboardButton
}

pub struct BotKeyboardButton {
pub:
	text          string
	callback_data string
}

pub struct BotInlineQuery {
pub:
	id     string
	sender BotUser @[json: 'from']
	query  string
	offset string
}

pub struct BotCallbackQuery {
pub:
	id            string
	sender        BotUser @[json: 'from']
	message       BotMessage
	chat_instance string
	data          string
}

pub struct BotUpdate {
pub:
	update_id      i64
	message        ?BotMessage
	inline_query   ?BotInlineQuery
	callback_query ?BotCallbackQuery
}

@[params]
pub struct BotUpdateOptions {
pub:
	offset i64
	limit  int = 100
}

// updates polls once. Pass the highest processed update ID plus one on the
// next call to acknowledge all earlier updates, including other update types.
pub fn (bot BotClient) updates(options BotUpdateOptions) ![]BotUpdate {
	updates := bot.post[[]BotUpdate]('getUpdates', json2.encode(options))!
	return updates.map(it.with_bot(bot))
}

fn (update BotUpdate) with_bot(bot BotClient) BotUpdate {
	message := if incoming := update.message { ?BotMessage(incoming.with_bot(bot)) } else { none }
	callback := if query := update.callback_query {
		?BotCallbackQuery(BotCallbackQuery{
			...query
			message: query.message.with_bot(bot)
		})
	} else {
		none
	}
	return BotUpdate{
		...update
		message:        message
		callback_query: callback
	}
}

// chat looks up an open direct conversation with this bot.
pub fn (bot BotClient) chat(chat_id int) !BotChat {
	chat := bot.post[BotChat]('getChat', json2.encode(BotMessageRequest{ chat_id: chat_id }))!
	return chat.with_bot(bot)
}

fn (chat BotChat) with_bot(bot BotClient) BotChat {
	return BotChat{
		...chat
		bot: bot
	}
}

fn (message BotMessage) with_bot(bot BotClient) BotMessage {
	return BotMessage{
		...message
		chat: message.chat.with_bot(bot)
	}
}

@[params]
pub struct BotSendOptions {
pub:
	reply_to_message_id int
	client_id           string
	reply_markup        ?BotReplyMarkup
}

@[params]
pub struct BotEditOptions {
pub:
	reply_markup ?BotReplyMarkup
}

struct BotReplyParameters {
	message_id int
}

struct BotMessageRequest {
	chat_id          int
	message_id       int                 @[omitempty]
	text             ?string             @[omitempty]
	reply_parameters ?BotReplyParameters @[omitempty]
	client_id        string              @[omitempty]
	reply_markup     ?BotReplyMarkup     @[omitempty]
}

// send_message sends plaintext. Reuse client_id to retry the same send.
pub fn (chat BotChat) send_message(text string, options BotSendOptions) !BotMessage {
	reply := if options.reply_to_message_id != 0 {
		?BotReplyParameters(BotReplyParameters{ message_id: options.reply_to_message_id })
	} else {
		none
	}
	body := json2.encode(BotMessageRequest{
		chat_id:          chat.id
		text:             text
		reply_parameters: reply
		client_id:        options.client_id
		reply_markup:     options.reply_markup
	})
	message := chat.bot.post[BotMessage]('sendMessage', body)!
	return message.with_bot(chat.bot)
}

// edit_message_text edits a message previously sent by this bot.
pub fn (chat BotChat) edit_message_text(message_id int, text string, options BotEditOptions) !BotMessage {
	body := json2.encode(BotMessageRequest{
		chat_id:      chat.id
		message_id:   message_id
		text:         text
		reply_markup: options.reply_markup
	})
	message := chat.bot.post[BotMessage]('editMessageText', body)!
	return message.with_bot(chat.bot)
}

// delete_message removes a message previously sent by this bot.
pub fn (chat BotChat) delete_message(message_id int) !bool {
	return chat.bot.post[bool]('deleteMessage', json2.encode(BotMessageRequest{
		chat_id:    chat.id
		message_id: message_id
	}))
}

pub fn (message BotMessage) edit_text(text string, options BotEditOptions) !BotMessage {
	return message.chat.edit_message_text(message.message_id, text, options)
}

pub fn (message BotMessage) delete() !bool {
	return message.chat.delete_message(message.message_id)
}
