#!/usr/bin/env ruby
# frozen_string_literal: true
require 'em-websocket'
require 'sqlite3'
require 'json'
require 'securerandom'

PORT = (ENV['PORT'] || 7070).to_i
HOST = ENV['HOST'] || '0.0.0.0'
DB_PATH = ENV['CHESS_DB'] || 'chess.db'

# see client.rb for a minimal ASCII terminal client:
# ruby client.rb [room_id]          (CHESS_HOST env var to override ws://localhost:7070)

class ChessGame
  FILES = ('a'..'h').to_a

  KNIGHT_OFFS = [[1,2],[2,1],[2,-1],[1,-2],[-1,-2],[-2,-1],[-2,1],[-1,2]]
  KING_OFFS   = [[1,0],[1,1],[0,1],[-1,1],[-1,0],[-1,-1],[0,-1],[1,-1]]
  BISHOP_DIRS = [[1,1],[1,-1],[-1,1],[-1,-1]]
  ROOK_DIRS   = [[1,0],[-1,0],[0,1],[0,-1]]

  attr_reader :board, :turn, :castling, :ep_target, :halfmove, :fullmove, :history

  def initialize
    @board = Array.new(64)
    back = %w[R N B Q K B N R]
    8.times { |f| @board[sq(f,0)] = "w#{back[f]}" }
    8.times { |f| @board[sq(f,1)] = "wP" }
    8.times { |f| @board[sq(f,6)] = "bP" }
    8.times { |f| @board[sq(f,7)] = "b#{back[f]}" }
    @turn = :w
    @castling = { wK: true, wQ: true, bK: true, bQ: true }
    @ep_target = nil
    @halfmove = 0
    @fullmove = 1
    @history = []
  end

  def sq(file, rank) = rank * 8 + file
  def file_of(i) = i % 8
  def rank_of(i) = i / 8
  def on_board?(f, r) = f.between?(0,7) && r.between?(0,7)

  def self.alg_to_idx(s)
    f = s[0].ord - 97
    r = s[1].to_i - 1
    r * 8 + f
  end

  def self.idx_to_alg(i)
    "#{FILES[i % 8]}#{i / 8 + 1}"
  end

  def self.from_fen(fen_str)
    g = allocate
    placement, active, cast, ep, half, full = fen_str.split(' ')
    board = Array.new(64)
    placement.split('/').each_with_index do |row, i|
      r = 7 - i
      f = 0
      row.each_char do |c|
        if c =~ /\d/
          f += c.to_i
        else
          color = c == c.upcase ? :w : :b
          board[r * 8 + f] = "#{color}#{c.upcase}"
          f += 1
        end
      end
    end
    g.instance_variable_set(:@board, board)
    g.instance_variable_set(:@turn, active == 'w' ? :w : :b)
    g.instance_variable_set(:@castling, {
      wK: cast.include?('K'), wQ: cast.include?('Q'),
      bK: cast.include?('k'), bQ: cast.include?('q')
    })
    g.instance_variable_set(:@ep_target, ep == '-' ? nil : alg_to_idx(ep))
    g.instance_variable_set(:@halfmove, half.to_i)
    g.instance_variable_set(:@fullmove, full.to_i)
    g.instance_variable_set(:@history, [])
    g
  end

  def color_of(piece) = piece.nil? ? nil : piece[0].to_sym
  def type_of(piece)  = piece.nil? ? nil : piece[1]
  def opponent(c) = c == :w ? :b : :w

  def pseudo_moves(from)
    piece = board[from]
    return [] unless piece
    color = color_of(piece)
    type = type_of(piece)
    f = file_of(from); r = rank_of(from)
    moves = []

    case type
    when 'P'
      dir = color == :w ? 1 : -1
      start_rank = color == :w ? 1 : 6
      promo_rank = color == :w ? 7 : 0
      if on_board?(f, r + dir)
        one = sq(f, r + dir)
        if board[one].nil?
          add_pawn_move(moves, from, one, promo_rank, r + dir)
          two = sq(f, r + 2*dir)
          moves << { from: from, to: two, double: true } if r == start_rank && board[two].nil?
        end
      end
      [-1, 1].each do |df|
        nf = f + df; nr = r + dir
        next unless on_board?(nf, nr)
        to = sq(nf, nr)
        if board[to] && color_of(board[to]) != color
          add_pawn_move(moves, from, to, promo_rank, nr)
        elsif to == ep_target
          moves << { from: from, to: to, ep: true }
        end
      end
    when 'N'
      KNIGHT_OFFS.each do |df, dr|
        nf, nr = f+df, r+dr
        next unless on_board?(nf, nr)
        to = sq(nf, nr)
        moves << { from: from, to: to } if board[to].nil? || color_of(board[to]) != color
      end
    when 'B' then slide(moves, from, BISHOP_DIRS, color)
    when 'R' then slide(moves, from, ROOK_DIRS, color)
    when 'Q' then slide(moves, from, BISHOP_DIRS + ROOK_DIRS, color)
    when 'K'
      KING_OFFS.each do |df, dr|
        nf, nr = f+df, r+dr
        next unless on_board?(nf, nr)
        to = sq(nf, nr)
        moves << { from: from, to: to } if board[to].nil? || color_of(board[to]) != color
      end
      add_castle_moves(moves, from, color)
    end
    moves
  end

  def add_pawn_move(moves, from, to, promo_rank, target_rank)
    if target_rank == promo_rank
      %w[Q R B N].each { |p| moves << { from: from, to: to, promo: p } }
    else
      moves << { from: from, to: to }
    end
  end

  def slide(moves, from, dirs, color)
    f = file_of(from); r = rank_of(from)
    dirs.each do |df, dr|
      nf, nr = f+df, r+dr
      while on_board?(nf, nr)
        to = sq(nf, nr)
        if board[to].nil?
          moves << { from: from, to: to }
        else
          moves << { from: from, to: to } if color_of(board[to]) != color
          break
        end
        nf += df; nr += dr
      end
    end
  end

  def add_castle_moves(moves, from, color)
    return if in_check?(color)
    rank = color == :w ? 0 : 7
    return unless from == sq(4, rank)
    ks = color == :w ? :wK : :bK
    qs = color == :w ? :wQ : :bQ
    opp = opponent(color)
    if castling[ks] && board[sq(5,rank)].nil? && board[sq(6,rank)].nil? &&
       !attacked?(sq(5,rank), opp) && !attacked?(sq(6,rank), opp)
      moves << { from: from, to: sq(6,rank), castle: :king }
    end
    if castling[qs] && board[sq(3,rank)].nil? && board[sq(2,rank)].nil? && board[sq(1,rank)].nil? &&
       !attacked?(sq(3,rank), opp) && !attacked?(sq(2,rank), opp)
      moves << { from: from, to: sq(2,rank), castle: :queen }
    end
  end

  # Is square idx attacked by color `by`?
  def attacked?(idx, by)
    f = file_of(idx); r = rank_of(idx)
    pdir = by == :w ? -1 : 1
    [-1,1].each do |df|
      nf, nr = f+df, r+pdir
      next unless on_board?(nf,nr)
      p = board[sq(nf,nr)]
      return true if p == "#{by}P"
    end
    KNIGHT_OFFS.each do |df,dr|
      nf,nr = f+df, r+dr
      next unless on_board?(nf,nr)
      return true if board[sq(nf,nr)] == "#{by}N"
    end
    KING_OFFS.each do |df,dr|
      nf,nr = f+df, r+dr
      next unless on_board?(nf,nr)
      return true if board[sq(nf,nr)] == "#{by}K"
    end
    BISHOP_DIRS.each do |df,dr|
      nf,nr = f+df, r+dr
      while on_board?(nf,nr)
        p = board[sq(nf,nr)]
        if p
          return true if color_of(p) == by && %w[B Q].include?(type_of(p))
          break
        end
        nf+=df; nr+=dr
      end
    end
    ROOK_DIRS.each do |df,dr|
      nf,nr = f+df, r+dr
      while on_board?(nf,nr)
        p = board[sq(nf,nr)]
        if p
          return true if color_of(p) == by && %w[R Q].include?(type_of(p))
          break
        end
        nf+=df; nr+=dr
      end
    end
    false
  end

  def king_square(color) = board.index("#{color}K")

  def in_check?(color)
    ks = king_square(color)
    ks && attacked?(ks, opponent(color))
  end

  def legal_moves_for(color)
    out = []
    64.times do |i|
      p = board[i]
      next unless p && color_of(p) == color
      pseudo_moves(i).each { |m| out << m if legal?(m, color) }
    end
    out
  end

  def legal?(move, color)
    snap = take_snapshot
    apply_move!(move)
    ok = !in_check?(color)
    restore_snapshot(snap)
    ok
  end

  def legal_moves(from)
    piece = board[from]
    return [] unless piece
    color = color_of(piece)
    pseudo_moves(from).select { |m| legal?(m, color) }
  end

  def take_snapshot
    [board.dup, turn, castling.dup, ep_target, halfmove, fullmove]
  end

  def restore_snapshot(s)
    @board, @turn, @castling, @ep_target, @halfmove, @fullmove = s
    @castling = @castling.dup
  end

  # Applies move without re-checking legality; updates full game state.
  def apply_move!(move)
    from, to = move[:from], move[:to]
    piece = board[from]
    color = color_of(piece)
    type = type_of(piece)
    captured = board[to]

    if move[:ep]
      cap_sq = sq(file_of(to), rank_of(from))
      board[cap_sq] = nil
      captured = 'ep'
    end

    board[to] = piece
    board[from] = nil
    board[to] = "#{color}#{move[:promo]}" if move[:promo]

    if move[:castle] == :king
      rank = rank_of(from)
      board[sq(5,rank)] = board[sq(7,rank)]
      board[sq(7,rank)] = nil
    elsif move[:castle] == :queen
      rank = rank_of(from)
      board[sq(3,rank)] = board[sq(0,rank)]
      board[sq(0,rank)] = nil
    end

    if type == 'K'
      if color == :w then castling[:wK] = false; castling[:wQ] = false
      else castling[:bK] = false; castling[:bQ] = false end
    end
    [from, to].each do |i|
      case i
      when sq(0,0) then castling[:wQ] = false
      when sq(7,0) then castling[:wK] = false
      when sq(0,7) then castling[:bQ] = false
      when sq(7,7) then castling[:bK] = false
      end
    end

    @ep_target = move[:double] ? sq(file_of(to), (rank_of(from)+rank_of(to))/2) : nil
    @halfmove = (type == 'P' || captured) ? 0 : halfmove + 1
    @fullmove += 1 if color == :b
    @turn = opponent(color)
    captured
  end

  # Public entry point used by the server.
  def make_move(from_alg, to_alg, promo = nil)
    from = self.class.alg_to_idx(from_alg)
    to = self.class.alg_to_idx(to_alg)
    piece = board[from]
    return { ok: false, error: 'no piece on that square' } unless piece
    color = color_of(piece)
    return { ok: false, error: 'not your turn' } unless color == turn

    candidates = legal_moves(from).select { |m| m[:to] == to }
    if candidates.any? { |m| m[:promo] }
      candidates = candidates.select { |m| m[:promo] == (promo || 'Q') }
    end
    move = candidates.first
    return { ok: false, error: 'illegal move' } unless move

    san = to_san(move)
    captured = apply_move!(move)
    history << san
    { ok: true, captured: !captured.nil?, status: status, san: san }
  end

  def to_san(move)
    return move[:castle] == :king ? 'O-O' : 'O-O-O' if move[:castle]
    piece = board[move[:from]]
    type = type_of(piece)
    from_s = self.class.idx_to_alg(move[:from])
    to_s = self.class.idx_to_alg(move[:to])
    capture = !board[move[:to]].nil? || move[:ep]
    base = type == 'P' ? (capture ? "#{from_s[0]}x#{to_s}" : to_s) : "#{type}#{capture ? 'x' : ''}#{to_s}"
    base += "=#{move[:promo]}" if move[:promo]
    base
  end

  def status
    color = turn
    moves = legal_moves_for(color)
    return in_check?(color) ? 'checkmate' : 'stalemate' if moves.empty?
    return 'check' if in_check?(color)
    return 'draw-50move' if halfmove >= 100
    'active'
  end

  def fen
    rows = []
    7.downto(0) do |r|
      row = ''; empty = 0
      8.times do |f|
        p = board[sq(f,r)]
        if p.nil?
          empty += 1
        else
          row += empty.to_s if empty > 0
          empty = 0
          c = type_of(p)
          row += color_of(p) == :w ? c : c.downcase
        end
      end
      row += empty.to_s if empty > 0
      rows << row
    end
    placement = rows.join('/')
    active = turn == :w ? 'w' : 'b'
    cast = ''
    cast += 'K' if castling[:wK]
    cast += 'Q' if castling[:wQ]
    cast += 'k' if castling[:bK]
    cast += 'q' if castling[:bQ]
    cast = '-' if cast.empty?
    ep = ep_target ? self.class.idx_to_alg(ep_target) : '-'
    "#{placement} #{active} #{cast} #{ep} #{halfmove} #{fullmove}"
  end
end

class Store
  def initialize(path)
    @db = SQLite3::Database.new(path)
    @db.execute <<~SQL
      CREATE TABLE IF NOT EXISTS rooms (
        id         TEXT PRIMARY KEY,
        fen        TEXT NOT NULL,
        history    TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    SQL
  end

  def load(id)
    row = @db.get_first_row('SELECT fen, history FROM rooms WHERE id = ?', [id])
    return nil unless row
    { fen: row[0], history: JSON.parse(row[1]) }
  end

  def save(id, fen, history)
    @db.execute(<<~SQL, [id, fen, history.to_json])
      INSERT INTO rooms (id, fen, history, updated_at)
      VALUES (?, ?, ?, datetime('now'))
      ON CONFLICT(id) DO UPDATE SET
        fen = excluded.fen, history = excluded.history, updated_at = excluded.updated_at
    SQL
  end
end

STORE = Store.new(DB_PATH)

class Room
  attr_reader :id, :game, :sockets
  def initialize(id, store)
    @id = id
    @store = store
    saved = store.load(id)
    if saved
      @game = ChessGame.from_fen(saved[:fen])
      saved[:history].each { |san| @game.history << san }
    else
      @game = ChessGame.new
    end
    @sockets = {} # ws => :w / :b / :spectator
  end

  def persist
    @store.save(id, game.fen, game.history)
  end

  def assign(ws)
    if !sockets.value?(:w)
      sockets[ws] = :w
    elsif !sockets.value?(:b)
      sockets[ws] = :b
    else
      sockets[ws] = :spectator
    end
    sockets[ws]
  end

  def remove(ws) = sockets.delete(ws)

  def broadcast(payload)
    msg = payload.to_json
    sockets.each_key { |ws| ws.send(msg) }
  end

  def state_payload(extra = {})
    {
      type: 'state',
      room: id,
      fen: game.fen,
      turn: game.turn,
      status: game.status,
      history: game.history,
      players: { w: sockets.value?(:w), b: sockets.value?(:b) },
      spectators: sockets.values.count { |v| v == :spectator }
    }.merge(extra)
  end
end

ROOMS = {}
ROOMS_MUTEX = Mutex.new

def find_or_create_room(id)
  ROOMS_MUTEX.synchronize { ROOMS[id] ||= Room.new(id, STORE) }
end

EM.run do
  EM::WebSocket.run(host: HOST, port: PORT) do |ws|
    room = nil
    role = nil

    ws.onopen do |handshake|
      path = handshake.path.to_s # e.g. /ws/AB12CD34
      room_id = path.split('/').last
      room_id = SecureRandom.hex(4) if room_id.nil? || room_id.empty? || room_id == 'ws'
      room = find_or_create_room(room_id)
      role = room.assign(ws)
      ws.send({ type: 'joined', room: room_id, color: role }.to_json)
      room.broadcast(room.state_payload)
    end

    ws.onmessage do |raw|
      begin
        msg = JSON.parse(raw, symbolize_names: true)
      rescue JSON::ParserError
        next ws.send({ type: 'error', message: 'bad json' }.to_json)
      end

      case msg[:type]
      when 'move'
        next ws.send({ type: 'error', message: 'spectators cannot move' }.to_json) unless role == :w || role == :b
        next ws.send({ type: 'error', message: 'not your turn' }.to_json) unless role == room.game.turn
        result = room.game.make_move(msg[:from].to_s, msg[:to].to_s, msg[:promo])
        if result[:ok]
          room.persist
          room.broadcast(room.state_payload(last_move: { from: msg[:from], to: msg[:to] }))
        else
          ws.send({ type: 'error', message: result[:error] }.to_json)
        end
      when 'chat'
        room.broadcast({ type: 'chat', role: role, text: msg[:text].to_s[0,500] })
      when 'sync'
        ws.send(room.state_payload)
      when 'resign'
        next unless role == :w || role == :b
        room.persist
        room.broadcast(room.state_payload(status: "resign-#{role}"))
      else
        ws.send({ type: 'error', message: 'unknown message type' }.to_json)
      end
    end

    ws.onclose do
      next unless room
      room.remove(ws)
      room.broadcast(room.state_payload)
    end
  end

  puts "server listening on ws://#{HOST}:#{PORT} (proxy to wss://chess.timosarkar.xyz/ws/*)"
end
