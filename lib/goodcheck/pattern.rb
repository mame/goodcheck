module Goodcheck
  module Pattern
    class Literal
      attr_reader :source
      attr_reader :case_sensitive

      def initialize(source:, case_sensitive:)
        @source = source
        @case_sensitive = case_sensitive
      end

      def regexp
        @regexp ||= ::Regexp.compile(::Regexp.escape(source), !case_sensitive)
      end
    end

    class Regexp
      attr_reader :source
      attr_reader :case_sensitive
      attr_reader :multiline

      def initialize(source:, case_sensitive:, multiline:, regexp: nil)
        @source = source
        @case_sensitive = case_sensitive
        @multiline = multiline
        @regexp = regexp
      end

      def regexp
        @regexp ||= begin
          options = 0
          options |= ::Regexp::IGNORECASE unless case_sensitive
          options |= ::Regexp::MULTILINE if multiline
          ::Regexp.compile(source, options)
        end
      end
    end

    class Token
      attr_reader :source, :case_sensitive, :variables

      def initialize(source:, variables:, case_sensitive:)
        @source = source
        @variables = variables
        @case_sensitive = case_sensitive
      end

      def regexp
        @regexp ||= Token.compile_tokens(source, variables, case_sensitive: case_sensitive)
      end

      class VarPattern
        attr_reader :negated
        attr_reader :patterns
        attr_accessor :type

        def initialize(patterns:, negated:)
          @patterns = patterns
          @negated = negated
        end

        def cast(str)
          case type
          when :int
            str.to_i
          when :float, :number
            str.to_f
          else
            str
          end
        end

        def test(str)
          return true if patterns.empty?

          unless negated
            patterns.any? {|pattern| test2(pattern, str) }
          else
            patterns.none? {|pattern| test2(pattern, str) }
          end
        end

        def test2(pattern, str)
          case pattern
          when Numeric
            pattern == cast(str)
          else
            pattern === str
          end
        end

        def self.empty
          VarPattern.new(patterns: [], negated: false)
        end
      end

      def test_variables(match)
        variables.all? do |name, var|
          str = match[name]
          str && var.test(str)
        end
      end

      @@TYPES = {}

      @@TYPES[:string] = -> (name) {
        ::Regexp.union(
          /"(?<#{name}>(?:[^"]|\")*)"/,
          /'(?<#{name}>(?:[^']|\')*)'/
        )
      }

      @@TYPES[:number] = -> (name) {
        ::Regexp.union(
          regexp_for_type(name: name, type: :int),
          regexp_for_type(name: name, type: :float)
        )
      }

      @@TYPES[:int] = -> (name) {
        ::Regexp.union(
          /(?<#{name}>[+-]?0|[1-9](:?\d|_\d)*)/,
          /(?<#{name}>[+-]?0[dD][0-7]+)/,
          /(?<#{name}>[+-]?0[oO]?[0-7]+)/,
          /(?<#{name}>[+-]?0[xX][0-9a-fA-F]+)/,
          /(?<#{name}>[+-]?0[bB][01]+)/
        )
      }

      @@TYPES[:float] = -> (name) {
        ::Regexp.union(
          /(?<#{name}>[+-]?\d+\.\d*(:?e[+-]?\d+)?)/,
          /(?<#{name}>[+-]?\d+(:?e[+-]?\d+)?)/
        )
      }

      @@TYPES[:word] = -> (name) {
        /(?<#{name}>\S+)/
      }

      @@TYPES[:identifier] = -> (name) {
        /(?<#{name}>[a-zA-Z_]\w*)\b/
      }

      # From rails_autolink gem
      # https://github.com/tenderlove/rails_autolink/blob/master/lib/rails_autolink/helpers.rb#L73
      # With ')' support, which should be frequently used for markdown or CSS `url(...)`
      AUTO_LINK_RE = %r{
        (?: ((?:ed2k|ftp|http|https|irc|mailto|news|gopher|nntp|telnet|webcal|xmpp|callto|feed|svn|urn|aim|rsync|tag|ssh|sftp|rtsp|afs|file):)// | www\. )
        [^\s<\u00A0")]+
      }ix

      # https://github.com/tenderlove/rails_autolink/blob/master/lib/rails_autolink/helpers.rb#L81-L82
      AUTO_EMAIL_LOCAL_RE = /[\w.!#\$%&'*\/=?^`{|}~+-]/
      AUTO_EMAIL_RE = /(?<!#{AUTO_EMAIL_LOCAL_RE})[\w.!#\$%+-]\.?#{AUTO_EMAIL_LOCAL_RE}*@[\w-]+(?:\.[\w-]+)+/

      @@TYPES[:url] = -> (name) {
        /\b(?<#{name}>#{AUTO_LINK_RE})/
      }

      @@TYPES[:email] = -> (name) {
        /\b(?<#{name}>#{AUTO_EMAIL_RE})/
      }

      def self.expand(prefix, suffix, depth: 5)
        if depth == 0
          [
            /[^#{suffix}]*/
          ]
        else
          expandeds = expand(prefix, suffix, depth: depth - 1)
          [/[^#{prefix}#{suffix}]*#{prefix}#{expandeds.first}#{suffix}[^#{prefix}#{suffix}]*/] + expandeds
        end
      end

      def self.regexp_for_type(name:, type:, scanner:)
        prefix = scanner.pre_match[-1]
        suffix = scanner.check(WORD_RE) || scanner.peek(1)

        case
        when type == :__
          body = case
                 when prefix == "{" && suffix == "}"
                   ::Regexp.union(expand(prefix, suffix))
                 when prefix == "(" && suffix == ")"
                   ::Regexp.union(expand(prefix, suffix))
                 when prefix == "[" && suffix == "]"
                   ::Regexp.union(expand(prefix, suffix))
                 when prefix == "<" && suffix == ">"
                   ::Regexp.union(expand(prefix, suffix))
                 else
                   unless suffix.empty?
                     /(?~#{::Regexp.escape(suffix)})/
                   else
                     /.*/
                   end
                 end
          /(?<#{name}>#{body})/

        when @@TYPES.key?(type)
          @@TYPES[type][name]
        end
      end

      WORD_RE = /\w+|[\p{L}&&\p{^ASCII}]+/

      def self.compile_tokens(source, variables, case_sensitive:)
        tokens = []
        s = StringScanner.new(source)

        until s.eos?
          case
          when s.scan(/\${(?<name>[a-zA-Z_]\w*)(?::(?<type>#{::Regexp.union(*@@TYPES.keys.map(&:to_s))}))?}/)
            name = s[:name].to_sym
            type = s[:type] ? s[:type].to_sym : :__

            if variables.key?(name)
              if !s[:type] && s.pre_match == ""
                Goodcheck.logger.error "Variable binding ${#{name}} at the beginning of pattern would cause an unexpected match"
              end
              if !s[:type] && s.peek(1) == ""
                Goodcheck.logger.error "Variable binding ${#{name}} at the end of pattern would cause an unexpected match"
              end

              tokens << :nobr
              variables[name].type = type
              regexp = regexp_for_type(name: name, type: type, scanner: s).to_s
              if tokens.empty? && (type == :word || type == :identifier)
                regexp = /\b#{regexp.to_s}/
              end
              tokens << regexp.to_s
              tokens << :nobr
            else
              tokens << ::Regexp.escape("${")
              tokens << ::Regexp.escape(name.to_s)
              tokens << ::Regexp.escape("}")
            end
          when s.scan(/\(|\)|\{|\}|\[|\]|\<|\>/)
            tokens << ::Regexp.escape(s.matched)
          when s.scan(/\s+/)
            tokens << '\s+'
          when s.scan(WORD_RE)
            tokens << ::Regexp.escape(s.matched)
          when s.scan(%r{[!"#%&'=\-^~¥\\|`@*:+;/?.,]+})
            tokens << ::Regexp.escape(s.matched.rstrip)
          when s.scan(/./)
            tokens << ::Regexp.escape(s.matched)
          end
        end

        if source[0] =~ /\p{L}/
          tokens.first.prepend('\b')
        end

        if source[-1] =~ /\p{L}/
          tokens.last << '\b'
        end

        options = ::Regexp::MULTILINE
        options |= ::Regexp::IGNORECASE unless case_sensitive

        buf, skip = tokens[0].is_a?(String) ? [tokens[0], false] : ["", true]
        tokens.drop(1).each do |tok|
          if tok == :nobr
            skip = true
          else
            buf << '\s*' unless skip
            skip = false
            buf << tok
          end
        end

        ::Regexp.new(buf.
          gsub(/\\s\*(\\s\+\\s\*)+/, '\s+').
          gsub(/#{::Regexp.escape('\s+\s*')}/, '\s+').
          gsub(/#{::Regexp.escape('\s*\s+')}/, '\s+'), options)
      end
    end
  end
end
