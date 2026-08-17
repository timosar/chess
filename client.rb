#!/usr/bin/env ruby
# frozen_string_literal: true
require 'websocket-client-simple'
require 'json'
require 'curses'

HOST = ENV['CHESS_HOST'] || 'wss://chess.timosarkar.xyz'
URL  = "#{HOST}/ws/#{ARGV[0] || ''}"

class ChessUI
  attr_reader :board_fen, :my_color, :status, :turn, :history, :chat_log, :input, :error_msg, :connected, :room

  def initialize
    @mutex     = Mutex.new
    @my_color  = nil
    @board_fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'
    @status    = 'connecting…'
    @turn      = '-'
    @history   = []
    @chat_log  = []
    @input     = +''
    @error_msg = nil
    @connected = false
    @room      = ARGV[0] || ''
    @ws        = nil
  end

  def board_lines(fen, color)
    rows = fen.split(' ').first.split('/')
    flip = color == :b
    rows = rows.reverse if flip

    lines = []
    lines << '  +-----------------+'
    rows.each_with_index do |row, i|
      rank = flip ? i + 1 : 8 - i
      cells = []
      row.each_char do |c|
        if c =~ /\d/
          c.to_i.times { cells << '.' }
        else
          cells << c
        end
      end
      cells = cells.reverse if flip
      lines << "#{rank} | #{cells.join(' ')} |"
    end
    lines << '  +-----------------+'
    files = flip ? '    h g f e d c b a' : '    a b c d e f g h'
    lines << files
    lines
  end

  def init_ui
    Curses.init_screen
    Curses.crmode
    Curses.noecho
    Curses.curs_set(1)
    Curses.start_color
    Curses.use_default_colors
    Curses.init_pair(1, Curses::COLOR_GREEN,  -1)
    Curses.init_pair(2, Curses::COLOR_YELLOW, -1)
    Curses.init_pair(3, Curses::COLOR_RED,    -1)
    Curses.init_pair(4, Curses::COLOR_CYAN,   -1)
    Curses.init_pair(5, Curses::COLOR_WHITE,  -1)
  end

  def draw
    Curses.clear
    h = Curses.lines
    w = Curses.cols

    board = board_lines(@board_fen, @my_color)
    board.each_with_index do |line, i|
      Curses.setpos(i + 1, 2)
      Curses.attron(Curses.color_pair(5)) { Curses.addstr(line) }
    end

    right_x = 28
    Curses.setpos(1, right_x)
    Curses.attron(Curses.color_pair(1) | Curses::A_BOLD) do
      Curses.addstr("Room: #{@room.empty? ? '(auto)' : @room}")
    end

    Curses.setpos(2, right_x)
    Curses.addstr("You  : #{@my_color || '…'}")
    Curses.setpos(3, right_x)
    Curses.attron(Curses.color_pair(2)) { Curses.addstr("Turn : #{@turn}") }
    Curses.setpos(4, right_x)
    Curses.addstr("Status: #{@status}")
    Curses.setpos(6, right_x)
    Curses.addstr("Moves:")
    hist = @history.last(8).join(' ')
    Curses.setpos(7, right_x)
    Curses.addstr(hist[0, w - right_x - 2] || '')

    log_top = 10
    log_h   = h - log_top - 4
    Curses.setpos(log_top, right_x)
    Curses.attron(Curses::A_BOLD) { Curses.addstr('Chat / Log') }

    visible = @chat_log.last(log_h)
    visible.each_with_index do |msg, i|
      Curses.setpos(log_top + 1 + i, right_x)
      color = msg.start_with?('[') ? 4 : (msg.start_with?('!') ? 3 : 1)
      Curses.attron(Curses.color_pair(color)) { Curses.addstr(msg[0, w - right_x - 2]) }
    end

    if @error_msg
      Curses.setpos(h - 3, 2)
      Curses.attron(Curses.color_pair(3) | Curses::A_BOLD) { Curses.addstr("! #{@error_msg}") }
    end

    Curses.setpos(h - 2, 2)
    Curses.addstr('e2e4 | e7e8q | chat <text> | resign | quit')
    Curses.setpos(h - 1, 2)
    Curses.addstr('> ' + @input)
    Curses.setpos(h - 1, 4 + @input.length)

    Curses.refresh
  end

  def log(msg)
    @chat_log << msg
    @chat_log.shift while @chat_log.size > 200
  end

  def start_ws
    @ws = WebSocket::Client::Simple.connect(URL)

    ui = self
    mutex = @mutex

    @ws.on :open do
      mutex.synchronize do
        ui.instance_variable_set(:@connected, true)
        ui.instance_variable_set(:@status, 'connected')
        ui.log("Connected to #{URL}")
        ui.draw
      end
    end

    @ws.on :message do |msg|
      data = begin
        JSON.parse(msg.data, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      return unless data

      mutex.synchronize do
        case data[:type]
        when 'joined'
          ui.instance_variable_set(:@my_color, data[:color].to_sym)
          ui.instance_variable_set(:@room, data[:room].to_s) if data[:room]
          ui.log("Joined room #{data[:room]} as #{data[:color]}")
          ui.log("Share room id: #{data[:room]}")
        when 'state'
          ui.instance_variable_set(:@board_fen, data[:fen])
          ui.instance_variable_set(:@turn, data[:turn].to_s)
          ui.instance_variable_set(:@status, data[:status].to_s)
          ui.history.replace(data[:history] || [])
        when 'error'
          ui.instance_variable_set(:@error_msg, data[:message])
          ui.log("! #{data[:message]}")
        when 'chat'
          ui.log("[#{data[:role]}] #{data[:text]}")
        end
        ui.draw
      end
    end

    @ws.on :close do |e|
      mutex.synchronize do
        ui.instance_variable_set(:@connected, false)
        ui.instance_variable_set(:@status, "disconnected (#{e.code})")
        ui.log("Disconnected (#{e.code})")
        ui.draw
      end
    end

    @ws.on :error do |e|
      mutex.synchronize do
        ui.log("Connection error: #{e.message}")
        ui.draw
      end
    end

    @ws
  end

  def handle_input(ch)
    @mutex.synchronize do
      @error_msg = nil

      case ch
      when 10, 13          # Enter
        line = @input.strip
        @input.clear
        if line =~ /quit|exit/
          return :quit
        elsif line == 'resign'
          @ws&.send({ type: 'resign' }.to_json)
        elsif line =~ /\Achat (.+)\z/
          @ws&.send({ type: 'chat', text: Regexp.last_match(1) }.to_json)
        elsif line =~ /\A([a-h][1-8])([a-h][1-8])([qrbn])?\z/i
          from, to, promo = Regexp.last_match(1), Regexp.last_match(2), Regexp.last_match(3)
          payload = { type: 'move', from: from, to: to }
          payload[:promo] = promo.upcase if promo
          @ws&.send(payload.to_json)
        else
          @error_msg = 'Unrecognized command'
          log("! Unrecognized: #{line}")
        end
      when 127, 8          # Backspace
        @input.chop! unless @input.empty?
      when 3, 27           # Ctrl-C or Esc
        return :quit
      else
        c = case ch
            when Integer then ch == 0 ? nil : ch.chr
            when String  then ch
            else nil
            end
        @input << c if c && c.bytes.first&.between?(32, 126)
      end
      draw
      nil
    end
  end
end

ui = ChessUI.new
ui.init_ui
ws = ui.start_ws
ui.draw

loop do
  ch = Curses.getch
  next if ch.nil?
  result = ui.handle_input(ch)
  break if result == :quit
end

Curses.close_screen
