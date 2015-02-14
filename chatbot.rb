require 'mumble-ruby'
require 'sqlite3'
require 'uri'
require 'video_info'
require 'logger'
require 'io/console'
require 'inifile'
require 'ruby-mpd'
require 'filewatcher'
require 'mechanize'
require './actions.rb'
require './tools.rb'
require './ethmmy.rb'

#Setup the parameters
file_paths = {}
connection_info = {}
misc_info = {}
settings_file = IniFile.load('settings.ini')
settings_file.each do |section,parameter,value|
	if section == 'FilePaths'
		file_paths[parameter] = value
	elsif section == 'ConnectionInfo'
		connection_info[parameter] = value
	elsif section == 'Misc'
		misc_info[parameter] = value
	end
end
@database_path 				= file_paths["database"]
@murmur_ini_path			= file_paths["murmurini"]
@chatlog_path				= file_paths["chatlog"]
@murmurlog_path				= file_paths["murmurlog"]
@restartbot_path			= file_paths["restartbot"]
@debuglog_path				= file_paths["debuglog"]
@ethmmy_subscriptions_path 	= file_paths["ethmmy_subscriptions"]
address 					= connection_info["address"]
port						= connection_info["port"]
@botname					= connection_info["botname"]
password 					= connection_info["password"]
@channel 					= misc_info["channel"]
mpd_server					= misc_info["mpdserver"]
mpd_port					= misc_info["mpdport"]
mpd_fifo					= misc_info["mpdfifo"]
ethmmy_username				= misc_info["ethmmy_username"]
ethmmy_password				= misc_info["ethmmy_password"]

spawn_file_watcher @ethmmy_subscriptions_path

#Initialize global variables and objects
@cli 									= Mumble::Client.new(address, port, @botname, password)
@mpd 									= MPD.new mpd_server, mpd_port
@agent 									= EthmmyAgent::Client.new(ethmmy_username,ethmmy_password)
@restart_signal 						= false
@logger 								= init_logger @chatlog_path
@debuglogger 							= init_logger @debuglog_path
@command_table 							= Hash.new {|h,k| h[k] = Array.new}
@usernames 								= {}
@channels								= Hash.new {|h,k| h[k] = Hash.new}
@channel_of_user						= {}
@ethmmy_agent_subscription_names 		= []
@emoticons 								= fetch_emoticons
@ethmmy_mumble_subscriptions			= fetch_ethmmy_subscriptions
@ethmmy_cached_announcements			= Hash.new {|h,k| h[k] = Array.new}
@ethmmy_subjects_ids					= {}

#Fetch data from the database
fetch_database

#Setup callbacks
@cli.on_user_state do |msg|
	unless msg.name.nil? #nil name (which is user name) means user just changed channel
		unless @usernames.empty?
			@usernames.each do |s,u|
				if u == msg.name
					@usernames.delete(s)
				end
			end
		end
		@usernames[msg.session] = msg.name
		@channel_of_user[@usernames[msg.session]] = @channels[msg.channel_id].name
	else
		@channel_of_user[@usernames[msg.session]] = @channels[msg.channel_id].name
		shout_cached_ethmmy_announcements msg
	end
end

@cli.on_text_message do |msg|	
	if msg.message.start_with?('.')
		@logger.unknown("[" + @channel + "] " + @usernames[msg.actor] + ":" + msg.message)
		msg.message[0] = ''
		msg.message = strip_html(msg.message)
		command = msg.message.split(' ')[0]
		#Search for the command in the table loaded from the database
		found = false
		index = -1
		@command_table[:names].each_with_index do |c,i|
			if command == c
				found = true
				index = i
				break
			end
		end
		unless found == false
			command_name = @command_table[:names][index]
			command_text = @command_table[:texts][index]
			command_type = @command_table[:types][index]
			command_alters_db = @command_table[:alters_db][index]
			command_privilege = @command_table[:execution_privilege][index]
			if authorized_user? @usernames[msg.actor],command_privilege #Chech in the database if the user is allowed to use this command
				#Call the function corresponding to the command with the "send" function
				if command_type == 'action'
					argument_list = msg.message.split(' ')
					argument_list.delete_at(0) #Chop the command
					send "#{command_type}_#{command_name}",@usernames[msg.actor],argument_list
				elsif command_type == 'text'
					send "#{command_type}",command_text
				end
				if command_alters_db == 'TRUE'
					fetch_database
				end
			else
				@cli.text_channel(@channel, "not allowed")
				@logger.unknown("[" + @channel + "] " + "Bot" + ":" + "not allowed")
			end
		end
	else
		#mumo issue fix. Server is not broadcasted as an entity at on_user_state.
		if @usernames[msg.actor].nil?
			@usernames[msg.actor] = 'Server'
		end
		#React to html stuff
		messages = parse_html(msg.message)
		if !(messages.empty?)
			@logger.unknown("[" + @channel + "] " + @usernames[msg.actor] + ":" + messages[1]) #Retain event sequence in logging
			@cli.text_channel(@channel, messages[0])
			@logger.unknown("[" + @channel + "] " + "Bot" + ":" + messages[0])
		else
			@logger.unknown("[" + @channel + "] " + @usernames[msg.actor] + ":" + msg.message)
		end
	end
end

@agent.on_new_announcement do |subject,body|
	announcement = subject+body
	@ethmmy_mumble_subscriptions.each do |user,user_subscriptions|
		unless ((@usernames.values.include? user) && (@channel == @channel_of_user[user]))
			if user_subscriptions.include? subject
				cache_ethmmy_announcement user,announcement
			end
		end
	end
	@cli.text_channel(@channel, announcement)
	@logger.unknown("[" + @channel + "] " + "Bot" + ":" + announcement)
end

@agent.on_debug_message do |msg|
	if msg == "Disconnected"
		@cli.text_channel(@channel,msg)
	end
	@debuglogger.unknown(msg)
end

on_file_change do
	old_subscriptions = @ethmmy_mumble_subscriptions.values.flatten.uniq
	new_subscriptions = (fetch_ethmmy_subscriptions).values.flatten.uniq
	unsubscribe_from = old_subscriptions - new_subscriptions
	subscribe_to = new_subscriptions - old_subscriptions
	unsubscribe_from.each do |subject|
		if @ethmmy_subjects_ids[subject]
			@agent.unsubscribe_from(@ethmmy_subjects_ids[subject])
			message = "Dropbox file changed, unsubscribed from #{subject}"
			@cli.text_channel(@channel,message)
			@logger.unknown("[" + @channel + "] " + "Bot" + ":" + message)
		else
			message = "Dropbox file changed, but #{subject} is not a valid course"
			@cli.text_channel()
		end
	end
	subscribe_to.each do |subject|
		if @ethmmy_subjects_ids[subject]
			@agent.subscribe_to(@ethmmy_subjects_ids[subject])
			message = "Dropbox file changed, subscribed to #{subject}"
			@cli.text_channel(@channel,message)
			@logger.unknown("[" + @channel + "] " + "Bot" + ":" + message)
		else
			message = "Dropbox file changed, but #{subject} is not a valid course"
			@cli.text_channel(@channel,message)
			@logger.unknown("[" + @channel + "] " + "Bot" + ":" + message)
		end
	end
	@ethmmy_mumble_subscriptions = fetch_ethmmy_subscriptions
end

#Connect the clients to the servers

#mpd
@mpd.connect

#mumble-ruby
@cli.connect
@channels = @cli.channels
sleep(1)
@cli.join_channel(@channel)
sleep(1)
@cli.player.stream_named_pipe(mpd_fifo)
sleep(1)

#ethmmy-agent
@agent.login
@ethmmy_agent_subscriptions = @agent.get_subscriptions
@ethmmy_subjects_ids = (@agent.get_all_courses).invert
@agent.spawn_announcement_poller(@ethmmy_agent_subscriptions)

while (@restart_signal == false)
	sleep(1)
end

#Call restartbot and disconnect
Dir.chdir (@restartbot_path) {
	Process.spawn('ruby', 'restartbot.rb')
}
@cli.disconnect