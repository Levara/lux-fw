# frozen_string_literal: true

# Controllers can be called in few ways
# Controller.call path
# Controller.action action_name, path
# Controller.new.action_name *args

# filters stack for call
# before, call, before_action, action, after

class Lux::Controller
  # define maser layout
  # string is template, symbol is metod pointer and lambda is lambda
  class_attribute :layout

  # define helper contest, by defult derived from class name
  class_attribute :helper

  # before and after any action filter, ignored in controllers, after is called just before render
  class_callbacks :before, :before_action, :before_render, :after, :on_error

  class << self
    # class call method, should not be overridden
    def call
      Lux.current.files_in_use.push "app/controllers/#{self.to_s.underscore}.rb"

      controller = new
      controller.filter :before
      controller.call

      return if Lux.current.response.body

      # we want to exec filter after the call
      controller.filter :before_action
    end

    # create mock function, to enable template rendering
    # mock :index, :login
    def mock *args
      args.each do |el|
        define_method el do
          true
        end
      end
    end

    # simple shortcut allows direct call to action, bypasing call
    def action *args
      new.action(*args)
    end
  end

  ### INSTANCE METHODS

  attr_reader :controller_action

  def initialize
    # before and after should be exected only once
    @executed_filters = {}
    @base_template = self.class.to_s.include?('::') ? self.class.to_s.sub(/Controller$/,'').underscore : self.class.to_s.sub(/Controller$/,'').downcase
  end

  # default action call method
  def call
    action_name   = nav.first
    action_name ||= @id ? :show : :index

    action action_name
  end

  # execute before and after filters, only once
  def filter fiter_name
    return if @executed_filters[fiter_name]
    @executed_filters[fiter_name] = true

    class_callback fiter_name

    !!response.body
  end

  def cache *args, &block
    Lux.cache.fetch *args, &block
  end

  # action(:show, 2)
  # action(:select', ['users'])
  def action method_name, *args
    raise ArgumentError.new('Controller action called with blank action name argument') if method_name.blank?

    # maybe before filter rendered page
    return if response.body

    method_name = method_name.to_s.gsub('-', '_').gsub(/[^\w]/, '')

    # dev console log
    Lux.log " #{self.class.to_s}(:#{method_name})".light_blue
    if im = self.class.instance_methods(false).first
      loc = self.class.instance_method(im).source_location[0].split(':').first
      loc = loc.sub(Lux.root.to_s+'/', '')

      Lux.log ' %s' % loc
      Lux.current.files_in_use.push loc
    end

    @controller_action = method_name

    # format error unless method found
    unless respond_to? method_name
      raise NotFoundError.new('Method %s not found' % method_name) unless Lux.config(:show_server_errors)

      list = methods - Lux::Controller.instance_methods
      err = [%[No instance method "#{method_name}" found in class "#{self.class.to_s}"]]
      err.push ["Expected so see def show(id) ..."] if method_name == 'show!'
      err.push %[You have defined \n- #{(list).join("\n- ")}]
      return Lux.error(err.join("\n\n"))
    end

    # run filters
    return if filter :before
    return if filter :before_action

    # catch error but forward unless handled
    begin
      send method_name, *args
    rescue => e
      class_callback :on_error, e
      raise e
    end

    return if filter :after

    render
  end

  # render :index
  # render 'main/root/index'
  # render text: 'ok'
  def render name=nil, opts={}
    if name.class == Hash
      opts.merge! name
    else
      opts[:template] = name
    end

    opts = opts.to_opts! :text, :html, :cache, :template, :json, :layout, :render_to_string, :data, :staus

    return if response.body
    return if @no_render

    filter :before_render

    render_resolve opts

    Lux.cache.set(opts[:cache], response.body) if opts[:cache]
  end

  # renders template to string
  def render_part
    Lux::Template.render_part("#{@base_template}/#{@controller_action}", instance_variables_hash, namespace)
  end

  def render_to_string name=nil, opts={}
    opts[:render_to_string] = true
    render name, opts
  end

  def send_file file, opts={}
    opts = opts.to_opts!(:type, :dialog, :name)
    opts.name ||= file.to_s.split('/').last

    response.header('content-disposition', 'attachment; filename=%s' % opts.name) if opts.dialog;
    response.response_type = opts.type if opts.type

    Lux::Current::StaticFile.deliver(file)
  end

  private
    # delegated to current
    define_method(:current)  { Lux.current }
    define_method(:request)  { current.request }
    define_method(:response) { current.response }
    define_method(:params)   { current.request.params }
    define_method(:nav)      { current.nav }
    define_method(:session)  { current.session }
    define_method(:get?)     { request.request_method == 'GET' }
    define_method(:post?)    { request.request_method == 'POST' }
    define_method(:redirect) { |where, flash={}| current.redirect where, flash }
    define_method(:etag)     { |*args| current.response.etag *args }

    # called be render
    def render_resolve opts
      # resolve basic types
      types = [ [:text, 'text/plain'], [:html, 'text/html'], [:json, 'application/json'] ]
      types.select{ |it| opts[it.first] }.each do |name, content_type|
        response.content_type = content_type
        return response.body(opts[name])
      end

      # resolve page data, without template
      page_data = opts.data || render_body(opts)

      # resolve data with layout
      page_data = render_layout opts, page_data

      # set body unless render to string
      response.body(page_data) unless opts.render_to_string

      page_data
    end

    def render_body opts
      if template = opts.template
        template = template.to_s
        template = "#{@base_template}/#{template}" unless template.starts_with?('/')
      else
        template = "#{@base_template}/#{@controller_action}"
      end

      Lux::Template.render_part(template, helper)
    end

    def render_layout opts, page_data
      layout = opts.layout
      layout = nil if layout.class == TrueClass
      layout = false if @layout.class == FalseClass

      if layout.class == FalseClass
        page_data
      else
        layout_define = layout || self.class.layout

        layout = case layout_define
          when String
            'layouts/%s' % layout_define
          when Symbol
            send(layout_define)
          when Proc
            layout_define.call
          else
            'layouts/%s' % @base_template.split('/')[0]
        end

        Lux::Template.new(layout, helper).render_part { page_data }
      end
    end

    def halt status, desc=nil
      response.status = status
      response.body   = desc || "Hatlt code #{status}"

      throw :done
    end

    def namespace
      @base_template.split('/')[0].to_sym
    end

    def helper ns=nil
      Lux::Helper.new self, :html, self.class.helper, ns
    end
end