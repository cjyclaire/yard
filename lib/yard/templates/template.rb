require 'erb'

module YARD
  module Templates
    module Template
      attr_accessor :class, :options, :subsections, :section
      
      class << self
        # @return [Array<Module>] a list of modules to be automatically included
        #   into any new template module
        attr_accessor :extra_includes

        # @private
        def included(klass)
          klass.extend(ClassMethods)
        end
      end
      
      self.extra_includes = []
      
      include Helpers::BaseHelper
      include Helpers::MethodHelper

      module ClassMethods
        attr_accessor :path, :full_path
        
        def full_paths
          included_modules.inject([full_path]) do |paths, mod|
            paths |= mod.full_paths if mod.respond_to?(:full_paths)
            paths
          end
        end
    
        def initialize(path, full_path)
          self.path = path
          self.full_path = Pathname.new(full_path)
          include_parent
          load_setup_rb
        end
      
        # Searches for a file identified by +basename+ in the template's
        # path as well as any mixed in template paths. 
        # 
        # @param [String] basename the filename to search for
        # @return [String] the full path of a file on disk with filename
        #   +basename+ in one of the template's paths.
        def find_file(basename)
          full_paths.each do |path|
            file = path.join(basename)
            return file if file.file?
          end

          nil
        end

        def is_a?(klass)
          return true if klass == Template
          super(klass)
        end

        # Creates a new template object to be rendered with {Template#run}
        def new(*args)
          obj = Object.new.extend(self)
          obj.class = self
          obj.send(:initialize, *args)
          obj
        end
      
        def run(*args)
          new(*args).run
        end
      
        def T(*path)
          Engine.template(*path)
        end
      
        private

        def include_parent
          pc = path.to_s.split('/')
          if pc.size > 1
            pc.pop
            include Engine.template!(pc.join('/'), full_path.join('..').cleanpath)
          end
        end

        def load_setup_rb
          setup_file = File.join(full_path, 'setup.rb')
          if File.file? setup_file
            module_eval(File.read(setup_file).taint, setup_file, 1)
          end
        end
      end
    
      def initialize(opts = {})
        @cache, @cache_filename = {}, {}
        @sections, @options = [], {}
        add_options(opts)
        
        extend(Helpers::HtmlHelper) if options[:format] == :html
        extend(Helpers::TextHelper) if options[:format] == :text
        extend(Helpers::UMLHelper) if options[:format] == :dot
        extend(*Template.extra_includes) unless Template.extra_includes.empty?

        init
      end
    
      # Loads a template specified by path. If +:template+ or +:format+ is
      # specified in the {#options} hash, they are prependend and appended
      # to the path respectively.
      # 
      # @param [Array<String, Symbol>] path the path of the template
      # @return [Template] the loaded template module
      def T(*path)
        path.unshift(options[:template]) if options[:template]
        path.push(options[:format]) if options[:format]
        self.class.T(*path)
      end
    
      # Sets the sections (and subsections) to be rendered for the template
      # 
      # @example Sets a set of erb sections
      #   sections :a, :b, :c # searches for a.erb, b.erb, c.erb
      # @example Sets a set of method and erb sections
      #   sections :a, :b, :c # a is a method, the rest are erb files
      # @example Sections with subsections
      #   sections :header, [:name, :children]
      #   # the above will call header.erb and only renders the subsections
      #   # if they are yielded by the template (see #yieldall)
      # @param [Array<Symbol, String, Template, Array>] args the sections
      #   to use to render the template. For symbols and strings, the
      #   section will be executed as a method (if one exists), or rendered 
      #   from the file "name.erb" where name is the section name. For 
      #   templates, they will have {Template.run} called on them. Any
      #   subsections can be yielded to using yield or {#yieldall}
      def sections(*args)
        @sections.replace(args) if args.size > 0
        @sections
      end
      
      # Initialization called on the template. Override this in a 'setup.rb'
      # file in the template's path to implement a template
      # 
      # @example A default set of sections
      #   def init
      #     sections :section1, :section2, [:subsection1, :etc]
      #   end
      def init
      end
    
      # Runs a template on +sects+ using extra options. This method should
      # not be called directly. Instead, call the class method {ClassMethods#run}
      # 
      # @param [Hash, nil] opts any extra options to apply to sections
      # @param [Array] sects a list of sections to render
      # @param [Fixnum] start_at the index in the section list to start from
      # @param [Boolean] break_first if true, renders only the first section
      # @yield [opts] calls for the subsections to be rendered
      # @yieldparam [Hash] opts any extra options to yield
      # @return [String] the rendered sections joined together
      def run(opts = nil, sects = sections, start_at = 0, break_first = false, &block)
        out = ""
        return out if sects.nil?
        sects = sects[start_at..-1] if start_at > 0
        add_options(opts) do
          sects.each_with_index do |s, index|
            next if Array === s
            self.section = s
            self.subsections = sects[index + 1]
            subsection_index = 0
            value = render_section(section) do |*args|
              value = with_section do
                run(args.first, subsections, subsection_index, true, &block)
              end
              subsection_index += 1 
              subsection_index += 1 until subsections.nil? ||
                subsections[subsection_index].nil? || 
                !subsections[subsection_index].is_a?(Array)
              value
            end
            out << (value || "")
            break if break_first
          end
        end
        out
      end
         
      # Yields all subsections with any extra options
      # 
      # @param [Hash] opts extra options to be applied to subsections
      def yieldall(opts = nil, &block)
        log.debug "Templates: yielding from #{inspect}"
        with_section { run(opts, subsections, &block) }
      end
    
      # @param [String, Symbol] section the section name
      # @yield calls subsections to be rendered
      # @return [String] the contents of the ERB rendered section
      def erb(section, &block)
        erb = ERB.new(cache(section), nil, '<>')
        erb.filename = cache_filename(section).to_s
        erb.result(binding, &block)
      end
      
      # @param [String] basename the name of the file
      # @return [String] the contents of a file identified by +basename+. All
      #   template paths (including any mixed in templates) are searched for
      #   the file
      # @see ClassMethods#find_file 
      def file(basename)
        file = self.class.find_file(basename)
        raise ArgumentError, "no file for '#{basename}' in #{self.class.path}" unless file
        file.read
      end
      
      def options=(value)
        @options = value
        set_ivars
      end
      
      def inspect
        "Template(#{self.class.path}) [section=#{section}]"
      end
    
      protected
    
      def erb_file_for(section)
        "#{section}.erb"
      end
    
      private
    
      def subsections=(value)
        @subsections = Array === value ? value : nil
      end
    
      def render_section(section, &block)
        log.debug "Templates: inside #{self.inspect}"
        case section
        when String, Symbol
          if respond_to?(section)
            send(section, &block) 
          else
            erb(section, &block)
          end
        when Module, Template
          section.run(options, &block) if section.is_a?(Template)
        end || ""
      end

      def cache(section)
        content = @cache[section.to_sym]
        return content if content
      
        file = self.class.find_file(erb_file_for(section))
        @cache_filename[section.to_sym] = file
        raise ArgumentError, "no template for section '#{section}' in #{self.class.path}" unless file
        @cache[section.to_sym] = file.read
      end
      
      def cache_filename(section)
        @cache_filename[section.to_sym]
      end
      
      def set_ivars
        options.each do |k, v|
          instance_variable_set("@#{k}", v)
        end
      end
    
      def add_options(opts = nil)
        return(yield) if opts.nil? && block_given?
        cur_opts = options if block_given?
        
        self.options = options.merge(opts)
      
        if block_given?
          value = yield
          self.options = cur_opts 
          value
        end
      end
      
      def with_section(&block)
        s1, s2 = section, subsections
        value = yield
        self.section, self.subsections = s1, s2
        value
      end
    end
  end
end

