require 'puppet/application'
require 'puppet/face'
require 'optparse'
require 'pp'

class Puppet::Application::FaceBase < Puppet::Application
  should_parse_config
  run_mode :agent

  option("--debug", "-d") do |arg|
    Puppet::Util::Log.level = :debug
  end

  option("--verbose", "-v") do
    Puppet::Util::Log.level = :info
  end

  option("--render-as FORMAT") do |format|
    self.render_as = format.to_sym
  end

  option("--mode RUNMODE", "-r") do |arg|
    raise "Invalid run mode #{arg}; supported modes are user, agent, master" unless %w{user agent master}.include?(arg)
    self.class.run_mode(arg.to_sym)
    set_run_mode self.class.run_mode
  end


  attr_accessor :face, :action, :type, :arguments, :render_as

  def render_as=(format)
    if format == :for_humans or format == :json
      @render_as = format
    elsif network_format = Puppet::Network::FormatHandler.format(format)
      method = network_format.render_method
      if method == "to_pson" then
        @render_as = :json
      else
        @render_as = method.to_sym
      end
    else
      raise ArgumentError, "I don't know how to render '#{format}'"
    end
  end

  def render(result)
    # Invoke the rendering hook supplied by the user, if appropriate.
    if hook = action.when_rendering(render_as) then
      result = hook.call(result)
    end

    if render_as == :for_humans then
      render_for_humans(result)
    elsif render_as == :json
      PSON::pretty_generate(result, :allow_nan => true, :max_nesting => false)
    else
      result.send(render_as)
    end
  end

  def render_for_humans(result)
    # String to String
    return result if result.is_a? String
    return result if result.is_a? Numeric

    # Simple hash to table
    if result.is_a? Hash and result.keys.all? { |x| x.is_a? String or x.is_a? Numeric }
      output = ''
      column_a = result.map do |k,v| k.to_s.length end.max + 2
      column_b = 79 - column_a
      result.sort_by { |k,v| k.to_s } .each do |key, value|
        output << key.to_s.ljust(column_a)
        output << PP.pp(value, '', column_b).
          chomp.gsub(/\n */) { |x| x + (' ' * column_a) }
        output << "\n"
      end
      return output
    end

    # ...or pretty-print the inspect outcome.
    return result.pretty_inspect
  end

  def preinit
    super
    Signal.trap(:INT) do
      $stderr.puts "Cancelling Face"
      exit(0)
    end
  end

  def parse_options
    # We need to parse enough of the command line out early, to identify what
    # the action is, so that we can obtain the full set of options to parse.

    # REVISIT: These should be configurable versions, through a global
    # '--version' option, but we don't implement that yet... --daniel 2011-03-29
    @type = self.class.name.to_s.sub(/.+:/, '').downcase.to_sym
    @face = Puppet::Face[@type, :current]

    # Now, walk the command line and identify the action.  We skip over
    # arguments based on introspecting the action and all, and find the first
    # non-option word to use as the action.
    action = nil
    index  = -1
    until @action or (index += 1) >= command_line.args.length do
      item = command_line.args[index]
      if item =~ /^-/ then
        option = @face.options.find do |name|
          item =~ /^-+#{name.to_s.gsub(/[-_]/, '[-_]')}(?:[ =].*)?$/
        end
        if option then
          option = @face.get_option(option)
          # If we have an inline argument, just carry on.  We don't need to
          # care about optional vs mandatory in that case because we do a real
          # parse later, and that will totally take care of raising the error
          # when we get there. --daniel 2011-04-04
          if option.takes_argument? and !item.index('=') then
            index += 1 unless
              (option.optional_argument? and command_line.args[index + 1] =~ /^-/)
          end
        elsif option = find_global_settings_argument(item) then
          unless Puppet.settings.boolean? option.name then
            # As far as I can tell, we treat non-bool options as always having
            # a mandatory argument. --daniel 2011-04-05
            index += 1          # ...so skip the argument.
          end
        elsif option = find_application_argument(item) then
          index += 1 if (option[:argument] and option[:optional])
        else
          raise OptionParser::InvalidOption.new(item.sub(/=.*$/, ''))
        end
      else
        @action = @face.get_action(item.to_sym)
      end
    end

    if @action.nil?
      if @action = @face.get_default_action() then
        @is_default_action = true
      else
        Puppet.err "#{face.name} does not have a default action, and no action was given"
        Puppet.err Puppet::Face[:help, :current].help(@face.name)
        exit false
      end
    end

    # Now we can interact with the default option code to build behaviour
    # around the full set of options we now know we support.
    @action.options.each do |option|
      option = @action.get_option(option) # make it the object.
      self.class.option(*option.optparse) # ...and make the CLI parse it.
    end

    # ...and invoke our parent to parse all the command line options.
    super
  end

  def find_global_settings_argument(item)
    Puppet.settings.each do |name, object|
      object.optparse_args.each do |arg|
        next unless arg =~ /^-/
        # sadly, we have to emulate some of optparse here...
        pattern = /^#{arg.sub('[no-]', '').sub(/[ =].*$/, '')}(?:[ =].*)?$/
        pattern.match item and return object
      end
    end
    return nil                  # nothing found.
  end

  def find_application_argument(item)
    self.class.option_parser_commands.each do |options, function|
      options.each do |option|
        next unless option =~ /^-/
        pattern = /^#{option.sub('[no-]', '').sub(/[ =].*$/, '')}(?:[ =].*)?$/
        next unless pattern.match(item)
        return {
          :argument => option =~ /[ =]/,
          :optional => option =~ /[ =]\[/
        }
      end
    end
    return nil                  # not found
  end

  def setup
    Puppet::Util::Log.newdestination :console

    @arguments = command_line.args

    # Note: because of our definition of where the action is set, we end up
    # with it *always* being the first word of the remaining set of command
    # line arguments.  So, strip that off when we construct the arguments to
    # pass down to the face action. --daniel 2011-04-04
    # Of course, now that we have default actions, we should leave the
    # "action" name on if we didn't actually consume it when we found our
    # action.
    @arguments.delete_at(0) unless @is_default_action

    # We copy all of the app options to the end of the call; This allows each
    # action to read in the options.  This replaces the older model where we
    # would invoke the action with options set as global state in the
    # interface object.  --daniel 2011-03-28
    @arguments << options

    # If we don't have a rendering format, set one early.
    self.render_as ||= (@action.render_as || :for_humans)
  end


  def main
    status = false

    # Call the method associated with the provided action (e.g., 'find').
    if @action
      begin
        # We need to do arity checking here because this is generic code
        # calling generic methods – that have argument defaulting.  We need to
        # make sure we don't accidentally pass the options as the first
        # argument to a method that takes one argument.  eg:
        #
        #   puppet facts find
        #   => options => {}
        #      @arguments => [{}]
        #   => @face.send :bar, {}
        #
        #   def face.bar(argument, options = {})
        #   => bar({}, {})  # oops!  we thought the options were the
        #                   # positional argument!!
        #
        # We could also fix this by making it mandatory to pass the options on
        # every call, but that would make the Ruby API much more annoying to
        # work with; having the defaulting is a much nicer convention to have.
        #
        # We could also pass the arguments implicitly, by having a magic
        # 'options' method that was visible in the scope of the action, which
        # returned the right stuff.
        #
        # That sounds attractive, but adds complications to all sorts of
        # things, especially when you think about how to pass options when you
        # are writing Ruby code that calls multiple faces.  Especially if
        # faces are involved in that. ;)
        #
        # --daniel 2011-04-27
        if (arity = @action.positional_arg_count) > 0
          unless (count = arguments.length) == arity then
            raise ArgumentError, "wrong number of arguments (#{count} for #{arity})"
          end
        end

        result = @face.send(@action.name, *arguments)
        puts render(result) unless result.nil?
        status = true
      rescue Exception => detail
        puts detail.backtrace if Puppet[:trace]

        case detail
        when ArgumentError then
          got, want = /\((\d+) for (\d+)\)/.match(detail.to_s).to_a.map {|x| x.to_i }
          Puppet.err "puppet #{@face.name} #{@action.name}: #{want} argument expected but #{got} given"
          Puppet.err "Try 'puppet help #{@face.name} #{@action.name}' for usage"

        else # generic exception handling, alas.
          Puppet.err detail.to_s
        end
      end
    else
      puts "#{face} does not respond to action #{arguments.first}"
      puts Puppet::Face[:help, :current].help(@face.name)
    end

    exit status
  end
end