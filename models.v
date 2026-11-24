module voltlib

// User is the authenticated account. The API sends its ID as a JSON string.
pub struct User {
	client Client @[skip]
pub:
	id           string
	name         string
	display_name string
}

pub struct Server {
	client Client @[skip]
pub:
	id           int
	name         string
	long_name    string
	description  string
	creator_id   int
	created_at   i64
	nr_members   int
	nr_unread    int
	has_logo     bool
	is_community bool
	is_verified  bool
	is_deleted   bool
	is_private   bool
	chats        []Chat
}

pub struct Chat {
	client Client @[skip]
pub:
	id                    int
	server_id             int
	name                  string
	creator_id            int
	is_private            bool
	visibility_restricted bool
	user1_id              int
	user2_id              int
	user_ids              string
	contact_user_id       int
	contact_nickname      string
	contact_display_name  string
	is_partner_online     bool
	last_msg_id           int
	last_msg_time         i64
	nr_unread             int
	discord_bridge_id     string
	tg_bridge_id          string
	enc_keys              string
	enc_epoch             int
	conversation          Conversation
	msgs                  []Message
}

pub struct Conversation {
pub:
	id         int
	user_id    int
	chat_id    int
	cleared_id int
	hidden     bool
	revision   int
}

pub struct ChatList {
pub:
	servers       []Server
	all_chats     []Chat
	conversations []Conversation
}

pub struct Message {
pub:
	id                   int
	text                 string
	user                 string
	user_id              int
	chat_id              int
	time                 i64
	is_dm                bool
	server_id            int
	server_name          string
	chat_name            string
	client_id            string
	reply_to_id          int
	reply_count          int
	thread_id            int
	thread_root_id       int
	thread_reply_count   int
	revision             int
	edited_at            i64
	pinned_at            i64
	is_deleted           bool
	reactions            []Reaction
	author_display_name  string
	author_is_premium    bool
	author_premium_emoji string
}

pub struct Reaction {
pub:
	name     string
	count    int
	user_ids []int
}
