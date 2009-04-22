#!/bin/env ruby

##
# Jabber listener and dispatcher using a DRb server.
# Inspired by: Geoffrey Grosenbach http://peepcode.com
# Modfied by: Miguel Barcos http://www.galar.com
##

require 'rubygems'
require 'xmpp4r'
require 'xmpp4r/roster'
require 'xmpp4r/vcard'
require 'drb'

require 'yaml'

Jabber::debug = true

config   = YAML.load_file('../config/config.yml')
username = config['jabberizer']['jid']
password = config['jabberizer']['password']
jabberizer_name = config['jabberizer']['name']

#########

class Jabber::JID

  ##
  # Convenience method to generate node@domain

  def to_short_s
    s = []
    s << "#@node@" if @node
    s << @domain
    return s.to_s
  end

end

class Jabberizer

  def initialize(jabberizer_name, username, password, config={}, stop_thread=true)
    @config          = config
    @friends_sent_to = []
    @friends_online  = {}
    @mainthread      = Thread.current
    @handlers        = {}

    login(username, password)
    create_initial_handlers
    listen_for_subscription_requests
    listen_for_presence_notifications
    listen_for_messages

    send_initial_presence(jabberizer_name)

    Thread.stop if stop_thread
  end

  def login(username, password)
    @jid    = Jabber::JID.new(username)
    @client = Jabber::Client.new(@jid)
    @client.connect
    @client.auth(password)
  end

  def create_initial_handlers
    config   = YAML.load_file('../config/config.yml')
    config['jabberizer_handlers'].keys.each do |k|
      if k.match /_handler$/ 
        register_handler(config['jabberizer_handlers'][k]['jid'], self)
      end
    end
  end

  def logout
    @mainthread.wakeup
    @client.close
  end

  def send_initial_presence(jabberizer_name)
    @client.send(Jabber::Presence.new.set_status("#{jabberizer_name} is now online at #{Time.now.utc}"))
  end

  def listen_for_subscription_requests
    @roster   = Jabber::Roster::Helper.new(@client)

    @roster.add_subscription_request_callback do |item, pres|
      if pres.from.domain == @jid.domain
        log "ACCEPTING AUTHORIZATION REQUEST FROM: " + pres.from.to_s
        @roster.accept_subscription(pres.from)
      end
    end
  end

  def listen_for_messages
    @client.add_message_callback do |m|
      unless m.type == :error
        puts "RECEIVED: " + m.body.to_s
        handle_first_message m
        case m.body.to_s
        when 'exit'
          handle_logout m
        when /^jbrake::/
          handle_jbrake m
        else
          handle_generic m
        end
      else
        log [m.type.to_s, m.body].join(": ")
      end
    end
  end

  def send_msg(from, message)
    msg = Jabber::Message.new(from, message)
    msg.type = :chat
    @client.send(msg)
  end

  def handle_first_message(m)
    unless known_client m
      send_msg(m.from, "I am a robot. You are connecting for the first time.")
      @friends_sent_to << m.from
    end
  end
  
  def known_client(m)
    @friends_sent_to.include?(m.from)
  end
  
  def handle_logout(m)
    send_msg(m.from, "Exiting ...")
    logout
  end
  
  def handle_jbrake(m)
    command = m.body.to_s.gsub(/^jbrake::/, '').lstrip
    result = notify_handler(m, command)
    send_msg(m.from, "just run ===> #{command}\n response is ====> #{result}")
  end
  
  def handle_generic(m)
    send_msg(m.from, "[#{Time.now.strftime('%m/%d/%Y %I:%M%p')}] *** #{m.body}***")
  end
  
  ##
  # TODO Do something with the Hash of online friends.
  
  def listen_for_presence_notifications
    @client.add_presence_callback do |m|
      case m.type
      when nil # status: available
        log "PRESENCE: #{m.from.to_short_s} is online"
        @friends_online[m.from.to_short_s] = true
      when :unavailable
        log "PRESENCE: #{m.from.to_short_s} is offline"
        @friends_online[m.from.to_short_s] = false
      end
    end
  end

  def send_message(to, message)
    log("Sending message to #{to}")
    send_msg(to, message)    
  end

  def log(message)
    puts(message) #if Jabber::debug
    puts("there are #{@friends_online.size} friends online")
  end
  
  def register_handler(name, handler)
    @handlers[name] = handler
  end
  
  def notify_handler(message, command)
    @handlers[message.from.to_short_s] ? @handlers[message.from.to_short_s].handle(command) : "No Handler with name #{message.from} Found for your request!"
  end
  
  def handle(command)
    puts "HANDLING THE STRING " + command
    command
  end
end

DRb.start_service("druby://localhost:7777", Jabberizer.new(jabberizer_name, username, password, config, false))
DRb.thread.join
