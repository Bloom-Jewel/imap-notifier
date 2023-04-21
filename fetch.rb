#!/usr/bin/env -S bundle exec ruby
require 'net/https'
require 'net/imap'
require 'json'
require 'time'
require 'uri'
Bundler.require :default, :default

CONFIG = YAML.safe_load(File.read(File.expand_path("../config.yml", __FILE__)), aliases: true, symbolize_names: true).freeze

def login(account, id: :null)
  enabled = account.fetch(:enable, true) &&
            !account.fetch(:user, nil).nil? &&
            !account.fetch(:pass, nil).nil?
  return $stderr.puts("user #{id} is disabled") unless enabled
  server_name = account[:server]
  server =  CONFIG[:servers][server_name.to_sym]
  return $stderr.puts("server #{server_name} not found") if server.nil?
  
  imap = Net::IMAP.new(server[:address], port: server.fetch(:port, 993), ssl: server.fetch(:ssl, true))
  imap.login account[:user], account[:pass]
  if block_given?
    yield imap, id
  else
    imap
  end
rescue => e
  $stderr.puts "user #{id} error: #{e.message} (#{e.class})"
  e.backtrace.each do |bt|
    $stderr.puts "  #{bt}"
  end
ensure
  imap&.logout if block_given?
end

def truncate(str, len)
  if str.size > len then
    str.slice(0, len - 3) + '...'
  else
    str
  end
end

def login_as(id, &block)
  login(CONFIG[:accounts][id.to_sym], id: id.to_sym, &block)
end

def login_all(accounts, &block)
  accounts.each do |id, account| login(account, id: id, &block) end
end

def obtain_selectable_boxes(imap, ref_name: '', pattern: '*')
  imap.list(ref_name, pattern).reject do |box|
    box.attr.include? :Noselect
  end
end

def decode_message(msg, decoder)
  case decoder
  when 'QUOTED-PRINTABLE'
    msg.unpack1('M').encode('utf-8', 'iso-8859-1')
  when 'BASE64'
    msg.unpack1('m*').encode('utf-8', 'iso-8859-1')
  else
    msg
  end
end

def dig_body_parts(structure, code)
  case code
  when 'TEXT'
    structure
  else
    indices = code.scan(/\d+/).map(&:to_i).map(&:pred)
    structure = structure.parts[indices.shift] while !(indices.empty? || structure.nil?)
    structure
  end
end

def scan_body_parts(structures, media: '', subtype: '')
  if Struct === structures then
    if structures.media_type == 'MULTIPART' then
      return scan_body_parts(structures.parts, media: media, subtype: subtype)
    elsif structures.media_type == 'TEXT' then
      return ['TEXT'] if subtype.empty? || structures.subtype == subtype
    end
  end
  stack = structures.is_a?(Array) ? structures : [structures]
  output = []
  stack.each_with_index do |header, id|
    if header.media_type == 'MULTIPART' then
      scan_body_parts(header.parts, media: media, subtype: subtype).each do |i|
        output << "#{id.succ}.#{i}"
      end
    else
      valid  = true
      valid &= media.empty? || header.media_type == media
      valid &= subtype.empty? || header.subtype == subtype
      output << "#{id.succ}" if valid
    end
  end
  output
end

def parse_emails(addresses)
  addresses.map do |address| "#{address.mailbox}@#{address.host}" end.join(', ')
end

if $0 == __FILE__ then
  def fetch_unread_messages(imap, id)
    account = CONFIG[:accounts][id]
    list = obtain_selectable_boxes(imap)
    messages = []
    [:All, :Junk].each do |flag|
      box = list.find do |box_| box_.attr.include?(flag) end
      next if box.nil?
      
      imap.public_send CONFIG[:debug] ? :examine : :select, box.name
      search_query = [
        'UNSEEN',
        'NOT', 'FROM ' + account[:user],
      ]
      message_ids = imap.search(search_query.join(' '))
      next if message_ids.empty?
      message_raws = imap.fetch(
        message_ids,
        ['ENVELOPE', 'BODYSTRUCTURE']
      )
      
      message_raws.each do |fetch_data|
        envelope = fetch_data.attr['ENVELOPE']
        structure = fetch_data.attr['BODYSTRUCTURE']
        mime_parts = []
        is_plain = true
        text_parts = scan_body_parts(structure, media: 'TEXT', subtype: 'PLAIN')
        if text_parts.empty?
          is_plain = false
          text_parts = scan_body_parts(structure, media: 'TEXT')
        end
        plain_keys  = text_parts.map do |k|
          ["BODY.PEEK[#{k}]"]
        end.flatten
        actual_keys  = plain_keys.map do |k| k.sub('.PEEK', '') end
        next if plain_keys.empty? && actual_keys.empty?
        imap.fetch(fetch_data.seqno, CONFIG[:debug] ? plain_keys : actual_keys).first
          .attr.each do |body_key, body_content|
            next unless body_key.start_with?('BODY')
            body_code = body_key[5..-1]
            body_structure = dig_body_parts(structure, body_code)
            msg = decode_message(body_content, body_structure.encoding)
            unless is_plain then
              msg = Nokogiri::HTML(msg).text
            end
            msg.gsub!(/(?:\r?\n\s*){2,}/m, "\r\n")
            mime_parts << msg
          end
        
        messages << [envelope, structure, mime_parts]
      end
    end
    if block_given?
      messages.each do |(envelope, structure, mime_parts)|
        yield ({key: id, data: account}), envelope, structure, mime_parts
      end
      nil
    else
      messages
    end
  end
  
  def send_discord_webhook(account, head, parts, body)
    CONFIG[:webhooks].values.each do |url|
      sender_data = head.from.first
      sender_email = parse_emails(head.from.first(1))
      if sender_data.name.nil? then
        sender_name = sender_email
      else
        sender_name = head.from.first.name
      end
      sender_name = truncate(sender_name, 64)
      
      data = {}
      data[:title] = head.subject
      data[:description] = [
        "**From:** #{sender_email}",
        !head.to.nil? ? "**To:** #{parse_emails(head.to)}" : '',
        !head.cc.nil? ? "**Cc:** #{parse_emails(head.cc)}" : '',
        !head.bcc.nil? ? "**Bcc:** #{parse_emails(head.bcc)}" : '',
        $/,
        body
      ].reject(&:empty?).join($/)
      data[:description] = truncate(data[:description], 4096)
      data[:author] = {name: sender_email}
      data[:footer] = {text: "Provided from #{account[:data][:user]}'s mailbox"}
      data[:timestamp] = Time.parse(head.date).iso8601
      
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        req = Net::HTTP::Post.new(uri.path)
        req.body = JSON.dump({username: sender_name, embeds: [data]})
        req.content_type = 'application/json'
        res = http.request req
        res.value
      ensure
        sleep 1.5
      end
    end
  end
  
  login_all CONFIG[:accounts] do |imap, id|
    fetch_unread_messages imap, id, &method(:send_discord_webhook)
  end
end
