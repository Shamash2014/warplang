require 'byebug'
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

QUOTES = { "'" => 'quote' }
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

      def cdr
        @val.slice(1..-1)
      end

      def quoted?
        false
      end
    end
  end
end

module Warp
  class EnvTable
    attr_reader :global
    def initialize(env = {})
      @global = env
      @additional = []
    end

    def exists?(env, var_ref)
      env.global.fetch(var_ref, nil)
    end

    def find(var_ref)
      if exists?(self, var_ref)
        @global[var_ref]
      else
        found = @additional.find do |env|
          self.exists?(env, var_ref)
        end

        if found
          found.find(var_ref)
        else
          raise 'Cannot found var in ENV: ' + var_ref.to_s
        end
      end
    end

    def add_frame(env)
      @additional << self.class.new(env)
      self
    end

    def add_var(var, val)
      @global[var] = val
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

ENV = Warp::EnvTable.new({
                           '#:n' => -> () { puts },
                           '#:g' => -> () { puts ENV.global },
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
                           }
                           })
def evaluate(input)
  if input.quoted? && !char?(input)
    input
  elsif char?(input) && input.quoted?
    ENV.find(input.val).call
  elsif symbol?(input)
    ENV.find(input.val)
  elsif list?(input) && symbol?(input.car)
    if input.car.val == :quote
      input.cdr
    elsif input.car.val == :bind
      cdr = input.val[1]
      var = if cdr.is_a?(Warp::Model::List)
              evaluate(cdr).val
            else
              cdr.val
            end

      if ENV.exists?(ENV, var)
        raise 'Var already bound'
      else
        ENV.add_var(var, evaluate(input.val[2]))
      end
      ENV.find(var)
    elsif input.car.val == :if
      _, test, success, error = input.val
      if evaluate(test).bool == 'true'
        evaluate(success)
      else
        evaluate(error)
      end
    else
      proc = ENV.find(input.car.val)
      args = input.val.slice(1..-1)
      proc.(*args.map{ |arg| evaluate(arg) })
    end
  else
    raise 'Cannot evaluate unknown expression: ' + input.to_s
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

  puts 'W.A.R.P Lang, version 0.0.12'
  puts 'Starting...'
  puts
  while buff = Readline.readline("::> ", true)

    # p Readline::HISTORY.to_a
    begin
      puts write(evaluate(read(buff)))
    rescue => e
      p "Runtime Error: " + e.message
    end
  end
end

repl()
