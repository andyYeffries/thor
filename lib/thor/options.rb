require 'thor/option'

class Thor

  # This is a modified version of Daniel Berger's Getopt::Long class, licensed
  # under Ruby's license.
  #
  class Options
    NUMERIC     = /(\d*\.\d+|\d+)/
    LONG_RE     = /^(--\w+[-\w+]*)$/
    SHORT_RE    = /^(-[a-z])$/i
    EQ_RE       = /^(--\w+[-\w+]*|-[a-z])=(.*)$/i
    SHORT_SQ_RE = /^-([a-z]{2,})$/i # Allow either -x -v or -xv style for single char args
    SHORT_NUM   = /^(-[a-z])#{NUMERIC}$/i

    # Receives a hash and makes it switches.
    #
    def self.to_switches(options)
      options.map do |key, value|
        case value
          when true
            "--#{key}"
          when Array
            "--#{key} #{value.map{ |v| v.inspect }.join(' ')}"
          when Hash
            "--#{key} #{value.map{ |k,v| "#{k}:#{v}" }.join(' ')}"
          when nil, false
            ""
          else
            "--#{key} #{value.inspect}"
        end
      end.join(" ")
    end

    attr_reader :arguments, :options, :trailing

    # Takes an array of switches. Each array consists of up to three
    # elements that indicate the name and type of switch. Returns a hash
    # containing each switch name, minus the '-', as a key. The value
    # for each key depends on the type of switch and/or the value provided
    # by the user.
    #
    # The long switch _must_ be provided. The short switch defaults to the
    # first letter of the short switch. The default type is :boolean.
    #
    # Example:
    #
    #   opts = Thor::Options.new(
    #      "--debug" => true,
    #      ["--verbose", "-v"] => true,
    #      ["--level", "-l"] => :numeric
    #   ).parse(args)
    #
    def initialize(switches={}, skip_arguments=false)
      @arguments, @shorts, @options = [], {}, {}
      @non_assigned_required, @non_assigned_arguments, @trailing = [], [], []

      @switches = switches.values.inject({}) do |mem, option|
        unless option.argument? && skip_arguments
          @non_assigned_required  << option if option.required?
          @non_assigned_arguments << option if option.argument?

          option.aliases.each do |short|
            @shorts[short.to_s] ||= option.switch_name
          end

          mem[option.switch_name] = option
        end
        mem
      end

      remove_duplicated_shortcuts!
    end

    def parse(args)
      @pile, @trailing = args.dup, []

      while peek
        if current_is_switch?
          case shift
            when SHORT_SQ_RE
              unshift($1.split('').map { |f| "-#{f}" })
              next
            when EQ_RE, SHORT_NUM
              unshift($2)
              switch = $1
            when LONG_RE, SHORT_RE
              switch = $1
          end

          switch = normalize_switch(switch)
          option = switch_option(switch)

          next if option.nil? || option.argument?

          check_requirement!(switch, option)
          @options[option.human_name] = parse_option(switch, option)
        else
          unless @non_assigned_arguments.empty?
            argument = @non_assigned_arguments.shift
            @options[argument.human_name] = parse_option(argument.switch_name, argument)
            @arguments << @options.delete(argument.human_name)
          else
            @trailing << shift
          end
        end
      end

      check_validity!
      @options
    end

    def self.split(args)
      arguments = []

      args.each do |item|
        break if item =~ /^-/
        arguments << item
      end

      return arguments, args[Range.new(arguments.size, -1)]
    end

    def parse_arguments(arguments, args)
      @pile = args.dup
      assigns = {}

      arguments.each do |_, argument|
        assigns[argument.human_name] = if peek
          parse_option(argument.switch_name, argument)
        else
          argument.default
        end
      end

      assigns
    end

    private

      def peek
        @pile.first
      end

      def shift
        @pile.shift
      end

      def unshift(arg)
        unless arg.kind_of?(Array)
          @pile.unshift(arg)
        else
          @pile = arg + @pile
        end
      end

      # Returns true if the current peek is a switch.
      #
      def current_is_switch?
        case peek
          when LONG_RE, SHORT_RE, EQ_RE, SHORT_NUM
            switch?($1)
          when SHORT_SQ_RE
            $1.split('').any? { |f| switch?("-#{f}") }
        end
      end

      # Returns true if the next value exists and is not a switch.
      #
      def current_is_value?
        peek && peek !~ /^-/
      end

      # Check if the given argument matches with a switch.
      #
      def switch?(arg)
        switch_option(arg) || @shorts.key?(arg)
      end

      # Returns the option object for the given switch.
      #
      def switch_option(arg)
        if arg =~ /^--(no|skip)-([-\w]+)$/
          @switches[arg] || @switches["--#{$2}"]
        else
          @switches[arg]
        end
      end

      # Check if the given argument is actually a shortcut.
      #
      def normalize_switch(arg)
        @shorts.key?(arg) ? @shorts[arg] : arg
      end

      # Receives switch, option and the current values hash and assign the next
      # value to it. At the end, remove the option from the array where non
      # assigned requireds are kept.
      #
      def parse_option(switch, option)
        @non_assigned_required.delete(option)

        type = if option.type == :default
          current_is_value? ? :string : :boolean
        else
          option.type
        end

        case type
          when :boolean
            if current_is_value?
              shift == "true"
            else
              @switches.key?(switch) || switch !~ /^--(no|skip)-([-\w]+)$/
            end
          when :string
            shift
          when :numeric
            parse_numeric(switch)
          when :hash
            parse_hash
          when :array
            parse_array
        end
      end

      # Runs through the argument array getting strings that contains ":" and
      # mark it as a hash:
      #
      #   [ "name:string", "age:integer" ]
      #
      # Becomes:
      #
      #   { "name" => "string", "age" => "integer" }
      #
      def parse_hash
        return shift if peek.is_a?(Hash)
        hash = {}

        while current_is_value? && peek.include?(?:)
          key, value = shift.split(':')
          hash[key] = value
        end
        hash
      end

      # Runs through the argument array getting all strings until no string is
      # found or a switch is found.
      #
      #   ["a", "b", "c"]
      #
      # And returns it as an array:
      #
      #   ["a", "b", "c"]
      #
      def parse_array
        return shift if peek.is_a?(Array)
        array = []

        while current_is_value?
          array << shift
        end
        array
      end

      # Check if the peel is numeric ofrmat and return a Float or Integer.
      # Otherwise raises an error.
      #
      def parse_numeric(switch)
        return shift if peek.is_a?(Numeric)
        unless peek =~ NUMERIC && $& == peek
          raise MalformattedArgumentError, "expected numeric value for '#{switch}'; got #{peek.inspect}"
        end
        $&.index('.') ? shift.to_f : shift.to_i
      end

      # Raises an error if the option requires an input but it's not present.
      #
      def check_requirement!(switch, option)
        if option.input_required?
          raise RequiredArgumentMissingError, "no value provided for required argument '#{switch}'" if peek.nil?
          raise MalformattedArgumentError, "cannot pass switch '#{peek}' as an argument" unless current_is_value?
        end
      end

      # Raises an error if @required array is not empty after parsing.
      #
      def check_validity!
        unless @non_assigned_required.empty?
          names = @non_assigned_required.map do |o|
            o.argument? ? o.human_name : o.switch_name
          end.join("', '")

          raise RequiredArgumentMissingError, "no value provided for required arguments '#{names}'"
        end
      end

      # Remove shortcuts that happen to coincide with any of the main switches
      #
      def remove_duplicated_shortcuts!
        @shorts.keys.each do |short|
          @shorts.delete(short) if @switches.key?(short)
        end
      end

  end
end
