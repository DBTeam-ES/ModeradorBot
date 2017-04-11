sis = require("posix")
HTTP = require('socket.http')
HTTPS = require('ssl.https')
curl = require('cURL')
URL = require('socket.url')
JSON = require('dkjson')
redis = require('redis')
clr = require 'term.colors'
db = redis.connect('127.0.0.1', 6379)
serpent = require('serpent')

function bot_init(on_reload) -- The function run when the bot is started or reloaded.
	
	config = dofile('config.lua') -- Load configuration file.
	assert(not (config.bot_api_key == "" or not config.bot_api_key), clr.red..'Insert the bot token in config.lua -> bot_api_key'..clr.reset)
	assert(#config.superadmins > 0, clr.red..'Insert your Telegram ID in config.lua -> superadmins'..clr.reset)
	assert(config.log.admin, clr.red..'Insert your Telegram ID in config.lua -> log.admin'..clr.reset)
	
	db:select(config.db or 0) --select the redis db
	
	misc, roles = dofile('utilities.lua') -- Load miscellaneous and cross-plugin functions.
	locale = dofile('languages.lua')
	gbans = dofile('data/gbans.lua')
	pfilos = dofile('data/gbans.lua')
	spammers = dofile('data/gbans.lua')
	pfilos = dofile('data/pfilos.lua')
	api = require('methods')
	now_ms = require('socket').gettime
	
	bot = api.getMe().result -- Get bot info
	bot.revision = io.popen('git rev-parse --short HEAD'):read()

	plugins = {} -- Load plugins.
	for i,v in ipairs(config.plugins) do
		local p = dofile('plugins/'..v)
		if p.triggers then
			for funct, trgs in pairs(p.triggers) do
				for i = 1, #trgs do
					-- interpret any whitespace character in commands just as space
					trgs[i] = trgs[i]:gsub(' ', '%%s+')
				end
				if not p[funct] then
					p.trgs[funct] = nil
					print(clr.red..funct..' triggers ignored in '..v..': '..funct..' function not defined'..clr.reset)
				end
			end
		end
		table.insert(plugins, p)
	end
	if config.bot_settings.multipurpose_mode then
		for i,v in ipairs(config.multipurpose_plugins) do
			local p = dofile('plugins/multipurpose/'..v)
			table.insert(plugins, p)
		end
	end

	print('\n'..clr.blue..'BOT RUNNING:'..clr.reset, clr.red..'[@'..bot.username .. '] [' .. bot.first_name ..'] ['..bot.id..']'..clr.reset..'\n')
	
	last_update = last_update or 0 -- Set loop variables: Update offset,
	last_cron = last_cron or os.time() -- the time of the last cron job,
	is_started = true -- whether the bot should be running or not.
	
	if on_reload then
		return #plugins
	else
		api.sendAdmin('*Bot started!*\n_'..os.date('On %A, %d %B %Y\nAt %X')..'_\n'..#plugins..' plugins loaded', true)
		start_timestamp = os.time()
		current = {h = 0}
		last = {h = 0}
	end
end

-- for resolve username
local function extract_usernames(msg)
	if msg.from then
		if msg.from.username then
			db:hset('bot:usernames', '@'..msg.from.username:lower(), msg.from.id)
		end
		db:sadd(string.format('chat:%d:members', msg.chat.id), msg.from.id)
	end
	if msg.forward_from and msg.forward_from.username then
		db:hset('bot:usernames', '@'..msg.forward_from.username:lower(), msg.forward_from.id)
	end
	if msg.new_chat_member then
		if msg.new_chat_member.username then
			db:hset('bot:usernames', '@'..msg.new_chat_member.username:lower(), msg.new_chat_member.id)
		end
		db:sadd(string.format('chat:%d:members', msg.chat.id), msg.new_chat_member.id)
	end
	if msg.left_chat_member then
		if msg.left_chat_member.username then
			db:hset('bot:usernames', '@'..msg.left_chat_member.username:lower(), msg.left_chat_member.id)
		end
		db:srem(string.format('chat:%d:members', msg.chat.id), msg.left_chat_member.id)
	end
	if msg.reply_to_message then
		extract_usernames(msg.reply_to_message)
	end
	if msg.pinned_message then
		extract_usernames(msg.pinned_message)
	end
end

local function collect_stats(msg)
	
	extract_usernames(msg)
	
	if msg.chat.type ~= 'private' and msg.chat.type ~= 'inline' and msg.from then
		db:hset('chat:'..msg.chat.id..':userlast', msg.from.id, os.time()) --last message for each user
		db:hset('bot:chats:latsmsg', msg.chat.id, os.time()) --last message in the group
	end
	
	--user stats
	if msg.from then
		db:hincrby('user:'..msg.from.id, 'msgs', 1)
	end
end

local function match_triggers(triggers, text)
  	if text and triggers then
		text = text:gsub('^(/[%w_]+)@'..bot.username, '%1')
		for i, trigger in pairs(triggers) do
			local matches = {}
	    	matches = { string.match(text, trigger) }
			if next(matches) then
	    		return matches, trigger
			end
		end
	end
end

local function on_msg_receive(msg, callback) -- The fn run whenever a message is received.
	--vardump('PARSED', msg)
	if not msg then
		return
	end

	if msg.chat.type ~= 'group' then --do not process messages from normal groups
		
		if msg.date < os.time() - 7 then return end -- Do not process old messages.
		if not msg.text then msg.text = msg.caption or '' end
		
		locale.language = db:get('lang:'..msg.chat.id) or 'es' --group language
		if not config.available_languages[locale.language] then
			locale.language = 'es'
		end
		
		collect_stats(msg)
		
		local continue = true
		local onm_success
		for i, plugin in pairs(plugins) do
			if plugin.onEveryMessage and not plugin.onChannelPost or not plugin.onEditedChannelPost then
				onm_success, continue = pcall(plugin.onEveryMessage, msg)
				if not onm_success then
--					api.sendAdmin('An #error occurred (preprocess).\n'..tostring(continue)..'\n'..locale.language..'\n'..msg.text)
				end
			end
			if not continue then return end
		end
		
		for i,plugin in pairs(plugins) do
			if plugin.triggers then
				local blocks, trigger = match_triggers(plugin.triggers[callback], msg.text)
				if blocks then
					
					if msg.chat.type ~= 'private' and msg.chat.type ~= 'inline' and not db:exists('chat:'..msg.chat.id..':settings') and not msg.service then --init agroup if the bot wasn't aware to be in
							misc.initGroup(msg.chat.id)
						end
					
					if config.bot_settings.stream_commands then --print some info in the terminal
					if plugin.triggers.onChannelPost or plugin.triggers.onEditedChannelPost then
						print(clr.reset..clr.blue..'['..os.date('%X')..']'..clr.red..' '..trigger..clr.reset..' -> ['..msg.chat.id..']')
						else
						print(clr.reset..clr.blue..'['..os.date('%X')..']'..clr.red..' '..trigger..clr.reset..' '..msg.from.first_name..' ['..msg.from.id..'] -> ['..msg.chat.id..']')
						end
					end

					--if not check_callback(msg, callback) then goto searchaction end
					local success, result = xpcall(plugin[callback], debug.traceback, msg, blocks) --execute the main function of the plugin triggered
					
					if not success then --if a bug happens
							print(result)
							if config.bot_settings.notify_bug then
								api.sendReply(msg, _("🐞 Sorry, a *bug* occurred"), true)
							end
    	      				api.sendAdmin('An #error occurred.\n'..result..'\n'..locale.language..'\n'..msg.text)
							return
						end
					
					if type(result) == 'string' then --if the action returns a string, make that string the new msg.text
						msg.text = result
					elseif not result then --if the action returns true, then don't stop the loop of the plugin's actions
						return
					end
				end
				
			end
		end
	else
		if msg.group_chat_created or (msg.new_chat_member and msg.new_chat_member.id == bot.id) then
			-- set the language
			--[[locale.language = db:get(string.format('lang:%d', msg.from.id)) or 'en'
			if not config.available_languages[locale.language] then
				locale.language = 'en'
			end]]
			
			-- send disclamer
			api.sendMessage(msg.chat.id, _([[
Hello everyone!
My name is %s, and I'm a bot made to help administrators in their hard work.
Unfortunately I can't work in normal groups, please ask the creator to convert this group to a supergroup.
]]):format(bot.first_name))
			
			-- log this event
			if config.bot_settings.stream_commands then
				print(string.format('%s[%s]%s Bot was added to a normal group %s%s [%d] -> [%d]',
					  clr.blue, os.date('%X'), clr.yellow, clr.reset, msg.from.first_name, msg.from.id, msg.chat.id))
			end
		end
	end
end

function is_anybot(usuario)
	local url = 'https://api.telegram.org/bot' .. config.bot_api_key .. '/sendMessage?chat_id=' ..usuario.. '&text='..usuario
	local dat = performRequest(url)
	local res = JSON.decode(dat)
	if res.ok == false and res.description == "Forbidden: bot can't send messages to bots" then
			if not usuario then
				return false
			else
				return usuario
			end
	elseif res.ok == false and res.description == "Forbidden: bot was blocked by the user" then
			if usuario then
				return false
			else
				return usuario
		end
	elseif res.ok == false and res.description == "Forbidden: bot can't initiate conversation with a user" then
			if usuario then
				return false
			else
				return usuario
		end
	end
end

function parseMessageFunction(update)
	
	db:hincrby('bot:general', 'messages', 1)
	
	local msg, function_key
	
	if update.message or update.edited_message or update.channel_post or update.edited_channel_post then
--	if update.message or update.edited_message then
		
		function_key = 'onTextMessage'
		
		if not update.message then
			if update.edited_message then
				update.edited_message.edited = true
				update.edited_message.original_date = update.edited_message.date
				update.edited_message.date = update.edited_message.edit_date
				function_key = 'onEditedMessage'
			elseif update.channel_post then
				update.channel_post.channel_post = true
				function_key = 'onChannelPost'
			elseif update.edited_channel_post then
				update.edited_channel_post.edited_channel_post = true
				update.edited_channel_post.original_date = update.edited_channel_post.date
				update.edited_channel_post.date = update.edited_channel_post.edit_date
				function_key = 'onEditedChannelPost'
			end
		end
		
		msg = update.message or update.edited_message or update.channel_post or update.edited_channel_post
--		msg = update.message or update.edited_message
		
		if msg.text then
		elseif msg.photo then
			msg.media = true
			msg.media_type = 'photo'
		elseif msg.audio then
			msg.media = true
			msg.media_type = 'audio'
		elseif msg.document then
			msg.media = true
			msg.media_type = 'document'
			if msg.document.mime_type == 'video/mp4' then
				msg.media_type = 'gif'
			end
		elseif msg.sticker then
			msg.media = true
			msg.media_type = 'sticker'
		elseif msg.video then
			msg.media = true
			msg.media_type = 'video'
		elseif msg.voice then
			msg.media = true
			msg.media_type = 'voice'
		elseif msg.contact then
			msg.media = true
			msg.media_type = 'contact'
		elseif msg.venue then
			msg.media = true
			msg.media_type = 'venue'
		elseif msg.location then
			msg.media = true
			msg.media_type = 'location'
		elseif msg.game then
			msg.media = true
			msg.media_type = 'game'
		elseif msg.left_chat_member then
			local anybotid = (is_anybot(msg.left_chat_member.id))
			msg.service = true
			if msg.left_chat_member.id == bot.id then
				msg.text = '###left_chat_member:mybot'
			elseif msg.left_chat_member.id ~= anybotid then
				msg.text = '###left_chat_member'
			else
				msg.text = '###left_chat_member:anybot'
			end
		elseif msg.new_chat_member then
			local anybotid = (is_anybot(msg.new_chat_member.id))
			msg.service = true
			if msg.new_chat_member.id == bot.id then
				msg.text = '###new_chat_member:mybot'
			elseif msg.new_chat_member.id ~= anybotid then
				msg.text = '###new_chat_member'
			else
				msg.text = '###new_chat_member:anybot'
			end
		elseif msg.new_chat_photo then
			msg.service = true
			msg.text = '###new_chat_photo'
		elseif msg.delete_chat_photo then
			msg.service = true
			msg.text = '###delete_chat_photo'
		elseif msg.group_chat_created then
    		msg.service = true
    		msg.text = '###group_chat_created'
		elseif msg.supergroup_chat_created then
			msg.service = true
			msg.text = '###supergroup_chat_created'
		elseif msg.channel_chat_created then
			msg.service = true
			msg.text = '###channel_chat_created'
		elseif msg.migrate_to_chat_id then
			msg.service = true
			msg.text = '###migrate_to_chat_id'
		elseif msg.migrate_from_chat_id then
			msg.service = true
			msg.text = '###migrate_from_chat_id'
		elseif msg.new_chat_title then
			msg.service = true
			msg.text = '###new_chat_title'
		elseif msg.pinned_message then
			msg.service = true
			msg.text = '###pinned_message'
		else
		--	callback = 'onUnknownType'
			print('Unknown update type') return
		end
		
		if msg.forward_from_chat then
			if msg.forward_from_chat.type == 'channel' then
				msg.spam = 'forwards'
			end
		end
		if msg.caption then
			local caption_lower = msg.caption:lower()
			if caption_lower:match('telegram%.me') or caption_lower:match('telegram%.dog') then
				msg.spam = 'links'
			end
		end
		if msg.entities then
			for i, entity in pairs(msg.entities) do
				if entity.type == 'text_mention' then
					msg.mention_id = entity.user.id
				end
				if entity.type == 'url' or entity.type == 'text_link' then
					local text_lower = msg.text or msg.caption
					text_lower = text_lower:lower()
					if text_lower:match('telegram%.me') or text_lower:match('telegram%.dog') then
						msg.spam = 'links'
					else
						msg.media_type = 'link'
						msg.media = true
					end
				end
			end
		end
		if msg.reply_to_message then
			msg.reply = msg.reply_to_message
			if msg.reply.caption then
				msg.reply.text = msg.reply.caption
			end
		end
	elseif update.inline_query then
		msg = update.inline_query
		msg.inline = true
		msg.chat = {id = msg.from.id, type = 'inline', title = 'inline'}
		msg.date = os.time()
		msg.text = '###inline:'..msg.query
		function_key = 'onInlineQuery'
	elseif update.chosen_inline_result then
		msg = update.chosen_inline_result
		msg.text = '###chosenresult:'..msg.query
		msg.chat = {type = 'inline', id = msg.from.id, title = msg.from.first_name}
		msg.message_id = msg.inline_message_id
		msg.date = os.time()
		function_key = 'onChosenInlineQuery'
	elseif update.callback_query then
		msg = update.callback_query
		msg.cb = true
		msg.text = '###cb:'..msg.data
		if msg.message then
			msg.original_text = msg.message.text
			msg.original_date = msg.message.date
			msg.message_id = msg.message.message_id
			msg.chat = msg.message.chat
		else --when the inline keyboard is sent via the inline mode
			msg.chat = {type = 'inline', id = msg.from.id, title = msg.from.first_name}
			msg.message_id = msg.inline_message_id
		end
		msg.date = os.time()
		msg.cb_id = msg.id
		msg.message = nil
		msg.target_id = msg.data:match('(-?%d+)$') --callback datas often (always) ship IDs. Create a shortcut
		function_key = 'onCallbackQuery'
	else
	--	function_key = 'onUnknownType'
		print('Unknown update type') return
	end
	
	return on_msg_receive(msg, function_key)
end

bot_init() -- Actually start the script. Run the bot_init function.

while is_started do -- Start a loop while the bot should be running.
	local res = api.getUpdates(last_update+1) -- Get the latest updates
	if res then
		clocktime_last_update = os.clock()
		for i, msg in ipairs(res.result) do -- Go through every new message.
			last_update = msg.update_id
			current.h = current.h + 1
			parseMessageFunction(msg)
		end
	else
		print('Connection error')
	end
end

print('Halted.\n')
