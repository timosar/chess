#!/usr/bin/env ruby
# frozen_string_literal: true
# CHESS_HOST   ws(s)://host:port   (default ws://localhost:7070)
require 'websocket-client-simple'
require 'json'

HOST = ENV['CHESS_HOST'] || 'ws://localhost:7070'
ROOM = ARGV[0] || ''
URL  = "#{HOST}/ws/#{ROOM}"

$stdout.sync = true
MUTEX = Mutex.new

MY_COLOR = nil # :w or :b, set on 'joined'

def render_board(fen)
  rows = fen.split(' ').first.split('/')
  flip = MY_COLOR == :b
  if flip
    rows = rows.reverse
  end
  lines = ['  +-----------------+']
  rows.each_with_index do |row, i|
    rank = flip ? i + 1 : 8 - i
    cells = []
    row.each_char do |c|
      if c =~ /\d/
        c.to_i.times { cells << '.' }
      else
        cells << c # ASCII: P N B R Q K p n b r q k
      end
    end
    cells = cells.reverse if flip
    lines << "#{rank} | #{cells.join(' ')} |"
  end
  lines << '  +-----------------+'
  files = flip ? '  h g f e d c b a' : '    a b c d e f g h'
  lines << files
  lines.join("\n")
end

ws = WebSocket::Client::Simple.connect(URL)

ws.on :open do
  puts "Connected to #{URL}"
end

ws.on :message do |msg|
  data = begin
    JSON.parse(msg.data, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end
  next unless data

  MUTEX.synchronize do
    case data[:type]
    when 'joined'
      MY_COLOR = data[:color].to_sym
      puts "\nJoined room #{data[:room]} as #{data[:color]}"
      puts "Share this room id so others can join/spectate: #{data[:room]}"
    when 'state'
      puts "\n#{render_board(data[:fen])}"
      puts "Turn: #{data[:turn]}  Status: #{data[:status]}"
      puts "FEN: #{data[:fen]}"
      puts "Moves: #{data[:history].join(' ')}" unless data[:history].empty?
    when 'error'
      puts "! #{data[:message]}"
    when 'chat'
      puts "[#{data[:role]}] #{data[:text]}"
    end
    print '> '
  end
end

ws.on :close do |e|
  puts "\nDisconnected (#{e.code})"
  exit 0
end

ws.on :error do |e|
  puts "Connection error: #{e.message}"
end

sleep 0.5 # let the handshake land before printing the prompt
puts "Commands: e2e4 (move) | e7e8q (promote) | chat <text> | resign | quit"
print '> '

loop do
  line = $stdin.gets
  break if line.nil?
  line = line.strip
  next if line.empty?

  case line
  when 'quit', 'exit'
    ws.close
    break
  when 'resign'
    ws.send({ type: 'resign' }.to_json)
  when /\Achat (.+)\z/
    ws.send({ type: 'chat', text: Regexp.last_match(1) }.to_json)
  when /\A([a-h][1-8])([a-h][1-8])([qrbn])?\z/i
    from, to, promo = Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3)
    payload = { type: 'move', from: from, to: to }
    payload[:promo] = promo.upcase if promo
    ws.send(payload.to_json)
  else
    puts 'unrecognized command. Try e2e4, e7e8q, chat <text>, resign, or quit.'
  end
  print '> '
end
