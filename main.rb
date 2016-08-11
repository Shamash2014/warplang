require 'byebug'
require 'forwardable'

module Warp
  class STDInport
    TOKENIZER = /\s*(,@|[('`,)]|"(?:[\\].|[^\\"])*"|;.*|[^\s('"`,;)]*)(.*)/

    attr_reader :line
    def initialize(input, **kwargs)
      if kwargs[:type] == 'file'
        @input = IO.new(input)
        @line = @input.readlines.first.scan(TOKENIZER).flatten.compact.to_enum
      else
        @input = input
        @initial = @input.scan(TOKENIZER).flatten.compact
        @line = ''
      end
      @type = kwargs[:type] || 'string'
    end


    def next_token
      if @line == ''
        start = @initial.first
        @line = @initial[1].scan(TOKENIZER).flatten.compact
      else
        start = @line.first
        @line = @line[1].scan(TOKENIZER).flatten.compact
      end

      if start == ''
        new = @line[1]
        if new == ''
          new
        else
          next_token
        end
      else
        start
      end
    end
  end
end

QUOTES = { "'" => 'quote', "`" => 'quasiquote', "," => "unquote", ",@" => "unquoteSplicing" }
def read_ahead(inport, input)
  if input == '('
    list = []
    while (nextone = inport.next_token)
      if nextone == ')'
        break
      elsif nextone == ''
        raise 'Unbalanced parens'
        break
      elsif nextone != ')'
        list << read_ahead(inport, nextone)
      else
        break
        raise 'Unbalanced parens'
      end
    end
    Warp::Model::List.new(list)
  elsif input == ')'
    raise 'Unexpected )'
  elsif QUOTES.keys.include?(input)
    list = [read_ahead(inport, QUOTES[input])]
    list << read_ahead(inport, inport.next_token)

    Warp::Model::List.new(list)
  elsif Warp.is_fixnum?(input)
    Warp::Model::Fixnum.new(input)
  elsif Warp.is_double?(input)
    Warp::Model::Double.new(input)
  elsif Warp.is_bool?(input)
    Warp::Model::Boolean.new(input)
  elsif Warp.is_char?(input)
    Warp::Model::Char.new(input)
  elsif Warp.is_string?(input)
    Warp::Model::String.new(Warp::Model::Char.new(input))
  elsif Warp.is_symbol?(input)
    Warp::Model::Symbol.new(input)
  else
    raise 'Type of value is unknown, cannot write'
  end
end

def read(raw)
  inport = Warp::STDInport.new(raw)
  read_ahead(inport, inport.next_token)
end

module Warp
  module Model
    class Fixnum
      attr_reader :val
      def initialize(num)
        @val = num.to_i
      end

      def to_s
        @val.to_s
      end

      def bool
        'true'
      end

      def quoted?
        true
      end
    end
  end
end

module Warp
  module Model
    class Double
      attr_reader :val
      def initialize(num)
        @val = num.to_f
      end

      def to_s
        @val.to_s
      end

      def bool
        'true'
      end

      def quoted?
        true
      end
    end
  end
end

module Warp
  module Model
    class Boolean
      attr_reader :val
      def initialize(bool)
        @val = bool
      end

      def bool
        self.val
      end

      def to_s
        case @val
        when 'true'
          @val
        when 'false'
          @val
        else
          nil
        end
      end

      def quoted?
        true
      end
    end
  end
end

module Warp
  module Model
    class Char
      attr_reader :val
      STRING_REGEX = /((?<![\\])['"])((?:.(?!(?<![\\])\1))*.?)\1/
      def initialize(char)
        if char.match(STRING_REGEX)
          @val = char.scan(STRING_REGEX).flatten.last
        else
          @val = char
        end
      end

      def bool
        'true'
      end

      def to_s
        @val
      end

      def quoted?
        true
      end
    end
  end
end

module Warp
  module Model
    class String
      attr_reader :val
      def initialize(chars)
        if chars.is_a?(Warp::Model::Char)
          @val = chars.val.split('').map{ |x| Warp::Model::Char.new(x) }
        elsif chars.is_a?(Warp::Model::List)
          @val = chars.val.flat_map(&:val).join('').split('').map{ |x| Warp::Model::Char.new(x) }
        else
          @val = chars.split('').map{ |x| Warp::Model::Char.new(x) }
        end
      end

      def to_s
        case @val
        when []
          ''
        else
          res = @val.reduce('') do |acc, val|
            acc << "#{val}"
          end

          "\"#{res}\""
        end
      end

      def bool
        'true'
      end

      def quoted?
        true
      end
    end
  end
end

module Warp
  module Model
    class Symbol
      attr_reader :val
      def initialize(val)
        @val = val.to_sym
      end

      def to_s
        @val.to_s
      end

      def bool
        'true'
      end

      def quoted?
        false
      end
    end
  end
end

module Warp
  module Model
    class List
      attr_reader :val
      def initialize(val)
        @val = []
        val.flatten.each do |chr|
          @val << chr
        end
      end

      def size
        @val.size
      end

      def map(&block)
        self.class.new(@val.reduce([]) do |acc, x|
          acc << block.call(x)
          acc
        end)
      end

      def to_s
        case @val
        when []
          '()'
        else
          res = @val.reduce('(') do |acc, val|
            acc << "#{val} "
          end
          res.strip << ')'
        end
      end

      def bool
        case @val
        when []
          'false'
        else
          'true'
        end
      end

      def car
        @val.first
      end

      def carvl
        @val.first.val
      end

      def cdr
        val = @val.slice(1..-1)
        if val.nil?
          []
        else
          val
        end
      end

      def cdr=list
        self.class.new([@val.first, list.val])
      end

      def quoted?
        false
      end
    end
  end
end

module Warp
  class EnvTable
    extend Forwardable
    attr_accessor :main, :outer
    def initialize(args =[], params =[], outer=nil)
      @main = args.zip(params).to_h
      @outer = outer
    end
    def_delegators :@main, :[], :[]=

    def find(var)
      return @main[var] if @main.has_key?(var)
      @outer&.find(var)
    end
  end
end

module Warp
  class << self
    def is_fixnum?(input)
      input.to_i.to_s == input
    end

    def is_bool?(input)
      input.match(/true|false/)
    end

    def is_char?(input)
      input.match(/#:[\w]+/)
    end

    def is_string?(input)
      input.match(/((?<![\\])['"])((?:.(?!(?<![\\])\1))*.?)\1/)
    end

    def is_symbol?(input)
      input.match(/\+|\*|\-|\%|<|>|=|\w+/)
    end

    def is_double?(input)
      input =~ /^[-+]?[0-9]*\.?[0-9]+$/
    end
  end
end

def symbol?(input)
  input.class == Warp::Model::Symbol
end

def list?(input)
  input.class == Warp::Model::List
end

def char?(input)
  input.class == Warp::Model::Char
end

def pair?(input)
  input.class == Warp::Model::List && input.val.size > 1
end

module Warp
  module Model
    class Function
      def initialize(params, expr, env)
        @params = params
        @expr = expr
        @env = env
      end

      def quoted?
        false
      end

      def to_s
        'function'
      end

      def call(*args)
        evaluate(@expr, Warp::EnvTable.new(@params, args, @env))
      end
    end
  end
end

ENV = Warp::EnvTable.new.tap do |ev|

                       ev.main.merge!({
                           '#:n' => -> () { puts },
                           '#:g' => -> () { puts ENV.main },
                           :+ => ->(*args) do
                             if args.find { |u| u.is_a?(Warp::Model::Double) }
                               Warp::Model::Double.new(args.map(&:val).reduce(:+))
                             elsif args.find { |u| u.is_a?(Warp::Model::String) }
                               raise 'Types mismatch, can\'t add String to Number'
                             else
                               Warp::Model::Fixnum.new(args.map(&:val).reduce(:+))
                             end
                           end,
                           :* => ->(*args) do
                             if args.find { |u| u.is_a?(Warp::Model::Double) }
                               Warp::Model::Double.new(args.map(&:val).reduce(:*))
                             else
                               Warp::Model::Fixnum.new(args.map(&:val).reduce(:*))
                             end
                           end,

                           :- => ->(*args) do

                              if args.find { |u| u.is_a?(Warp::Model::Double) }
                                Warp::Model::Double.new(args.map(&:val).reduce(:-))
                              elsif args.find { |u| u.is_a?(Warp::Model::String) }
                                raise 'Types mismatch, can\'t add String to Number'
                              else
                                Warp::Model::Fixnum.new(args.map(&:val).reduce(:-))
                              end
                           end,

                          :'%' => ->(*args) do
                             if args.find { |u| u.is_a?(Warp::Model::Double) }
                               Warp::Model::Double.new(args.map(&:val).reduce(:%))
                             elsif args.find { |u| u.is_a?(Warp::Model::String) }
                               raise 'Types mismatch, can\'t add String to Number'
                             else
                               Warp::Model::Fixnum.new(args.map(&:val).reduce(:%))
                             end
                           end,

                          :'<' => ->(*args) do
                             list = []
                             args.map(&:val).each_cons(2) { |x, y| list << (x < y) }
                             Warp::Model::Boolean.new(list.all?.to_s)
                           end,

                          :'>' => ->(*args) do
                             list = []
                             args.map(&:val).each_cons(2) { |x, y| list << (x > y) }
                             Warp::Model::Boolean.new(list.all?.to_s)
                           end,

                          :'=' => ->(*args) do
                            list = []
                            args.map(&:val).each_cons(2) { |x, y| list << (x == y) }
                            Warp::Model::Boolean.new(list.all?.to_s)
                           end,

                          :'++' => ->(*args) do

                             if args.flatten.all? { |x| x.is_a?(Warp::Model::List) }
                               Warp::Model::List.new args.flatten.map(&:val)
                             elsif args.flatten.all? { |x| x.is_a?(Warp::Model::String) }
                               Warp::Model::String.new args.flat_map(&:val).join('')
                             else
                               raise 'Can\'t concatenate values. Please use + instead'
                             end
                           end,

                          :'bool?' => ->(*args) {
                             Warp::Model::Boolean.new args.map { |x|  x.is_a?(Warp::Model::Boolean) }.all?.to_s
                           },
                          :'fixnum?' => ->(*args) {
                             Warp::Model::Boolean.new args.map { |x|  x.is_a?(Warp::Model::Fixnum) }.all?.to_s
                           },
                          :'str?' => ->(*args) {
                             Warp::Model::Boolean.new args.map { |x|  x.is_a?(Warp::Model::String) }.all?.to_s
                           },
                          :'sym?' => ->(*args) {
                             Warp::Model::Boolean.new args.map { |x|  x.is_a?(Warp::Model::Symbol) }.all?.to_s
                           },


                          :'bound?' => ->(*args) {
                             Warp::Model::Boolean.new args.map { |x|  ENV.exists?(ENV, x.val) }.all?.to_s
                           },

                          :'str!' => -> (*args) {
                             unless args.find { |x| x.is_a?(Warp::Model::List) }
                               Warp::Model::String.new args.map(&:to_s).flatten.join('')
                             else
                               raise 'Can\'t cast List to String'
                             end
                           },

                          :'sym!' => -> (*args) {
                             unless args.find { |x| x.is_a?(Warp::Model::List) }
                               Warp::Model::Symbol.new args.flat_map(&:val).map(&:to_s).join('')
                             else
                               raise 'Can\'t cast List to Symbol'
                             end
                           },

                          :'double?' => ->(*args) {

                             Warp::Model::Boolean.new args.map { |x|  x.is_a?(Warp::Model::Double) }.all?.to_s
                           },
                          :cons => ->(head, *rest) {
                             if rest.flatten.all? { |x| x.is_a?(Warp::Model::List) }
                               return Warp::Model::List.new [head] + rest.flatten.map(&:val)
                             elsif rest.flatten.all? { |x| x.is_a?(Warp::Model::String) }
                               return Warp::Model::String.new Warp::Model::List.new [head] + rest.flatten.map(&:val)
                             else
                               Warp::Model::List.new [head].concat(rest)
                             end
                           },
                          :head => -> (list) {
                             unless list.first.is_a?(Warp::Model::List)
                               nil
                             else
                               list.first.car
                             end
                           },
                          :tail => -> (list) {
                             unless list.first.is_a?(Warp::Model::List)
                               nil
                             else
                               Warp::Model::List.new list.first.cdr
                             end
                           },
                          :list => -> (*args) {
                             Warp::Model::List.new args
                                        },
                          :join => ->(coll, *el) {
                               Warp::Model::List.new [coll.val].concat([el])
                                        },
                           })
end

MACRO_TABLE = {}

def expand(input, env = ENV)
  if !list?(input)
    input
  elsif list?(input) && input.carvl == :quote
    raise 'Syntax error, quote must have proceeding expression' if input.size < 2
    input
  elsif list?(input) && input.carvl == :if
    raise 'Syntax error, if must have success and error case' if input.size < 3
    symb, pred, succ, err = input.val
    Warp::Model::List.new(
      [
        symb,
        expand(pred),
        expand(succ),
        expand(err)
      ]
    )
  elsif list?(input) && input.carvl == :bind
    raise 'Syntax error, bind must have symbol expression supplied' if input.size < 3
    symb, sym, expr = input.val
    Warp::Model::List.new([
                            symb,
                            sym,
                            expand(expr)
                          ])
  elsif list?(input) && input.carvl == :fn
    sym, vars, body = input.val
    raise 'Syntax error, fn expected at least 3 expressions' unless input.size >= 3
    raise 'Syntax error, illegal lambda arguments list' if !vars.val.all? { |x| x.class == Warp::Model::Symbol }
    Warp::Model::List.new([
                            sym,
                            vars,
                            expand(body)
                          ])
  elsif list?(input) && input.carvl == :defmacro
    proc = evaluate(expand(input.val[2]))
    name = input.val[1]
    MACRO_TABLE[name.val] = proc
    nil
  elsif list?(input) && :quasiquote == input.carvl
    expand_quote(*input.cdr)
  elsif list?(input) && symbol?(input.car) && MACRO_TABLE.has_key?(input.car.val)
    expand(MACRO_TABLE[input.car.val].call(*input.cdr))
  else
    p MACRO_TABLE.has_key?(input.car.val)

    input.map do |val|
      expand(val)
    end
  end
end

def expand_quote(x)
  if x.nil?
    Warp::Model::List.new []
  elsif x.class != Warp::Model::List
    Warp::Model::List.new([
                            Warp::Model::Symbol.new('quote'),
                            x
                          ])
  elsif x&.carvl == :unquote
    x.cdr
  elsif x&.carvl == :unquoteSplicing
    p 'Splicing'
    Warp::Model::List.new([
                            Warp::Model::Symbol.new(:push),
                            expand_quote(x.cdr.first),
                            expand(x.cdr.slice(1..-1))
                          ])
  else
    Warp::Model::List.new([
                            Warp::Model::Symbol.new(:join),
                            x.car,
                            x.cdr.map { |y| expand_quote(y) }
                          ])
  end
end

def evaluate(input, env = ENV)
  if input.nil?
    print
  elsif input.quoted? && !char?(input)
    input
  elsif char?(input) && input.quoted?
    env.find(input.val).call
  elsif symbol?(input)
    env.find(input.val)
  elsif list?(input) && symbol?(input.car)
    if input.car.val == :quote
      input.cdr.first
    elsif input.car.val == :bind
      cdr = input.val[1]
      var = if cdr.is_a?(Warp::Model::List)
              evaluate(cdr, env).val
            else
              cdr.val
            end

      if env.find(var)
        raise 'Var already bound'
      else
        env[var] = evaluate(input.val[2], env)
      end
      env.find(var)
    elsif input.car.val == :if
      _, test, success, error = input.val
      if evaluate(test, env).bool == 'true'
        evaluate(success, env)
      else
        evaluate(error, env)
      end
    elsif input.car.val == :fn
      params, body = input.cdr
      Warp::Model::Function.new(params.val.map(&:val), body, env)
    elsif input.car.val == :do
      input.cdr.map do |exp|
        evaluate(exp, env)
      end.last
    else
      proc = env.find(input.car.val)
      args = input.val.slice(1..-1)
      proc.(*args.map{ |arg| evaluate(arg, env) })
    end
  else
    if evaluate(input.car, env).is_a?(Warp::Model::Function)
      proc = evaluate(input.car, env)
      args = input.val.slice(1..-1)
      return proc.(*args.map{ |arg| evaluate(arg, env) })
    else
      raise 'Cannot evaluate unknown expression: ' + input.to_s
    end
  end
end

def write(input)
  begin
    input.to_s
  rescue => e
    puts e
  end
end

def repl(args={})
  require 'readline'
  stty_save = %x`stty -g`.chomp
  trap("INT") { system "stty", stty_save; exit }

  puts 'W.A.R.P Lang, version 0.0.13'
  puts 'Starting...'
  puts
  while buff = Readline.readline("::> ", true)

    # p Readline::HISTORY.to_a
    begin
      puts write(evaluate(expand(read(buff))))
    rescue => e
      p "Runtime Error: " + e.message
    end
  end
end

repl()
