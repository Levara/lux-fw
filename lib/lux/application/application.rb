# frozen_string_literal: true

# Main application router

class Lux::Application
  class_callback :config    # pre boot app config
  class_callback :web_boot  # rack_handler is passed as argument
  class_callback :info      # called by "lux config" cli
  class_callback :before    # before any page load
  class_callback :routes    # routes resolve
  class_callback :after     # after any page load

  web_boot do |rack_handler|
    # deafult host is required
    unless Lux.config.host.to_s.include?('http')
      raise 'Invalid "Lux.config.host"'
    end

    if Lux.config(:dump_errors)
      require 'better_errors'

      rack_handler.use BetterErrors::Middleware
      BetterErrors.editor = :sublime
    end
  end

  ###

  attr_reader :route_target, :current

  # define common http methods as get? methods
  [:get, :head, :post, :delete, :put, :patch].map(&:to_s).each do |m|
    define_method('%s?' % m) { @current.request.request_method == m.upcase }
  end

  # simple one liners and delegates
  define_method(:request)  { @current.request }
  define_method(:params)   { @current.request.params }
  define_method(:nav)      { @current.nav }
  define_method(:redirect) { |where, flash={}| @current.redirect where, flash }
  define_method(:body?)    { response.body? }

  def initialize current
    raise 'Config is not loaded (Lux.start not called), cant render page' unless Lux.config.lux_config_loaded

    @current = current
  end

  # Triggers HTTP page error
  # ```
  # error.not_found
  # error.not_found 'Doc not fount'
  # error(404)
  # error(404, 'Doc not fount')
  # ```
  def error code=nil, message=nil
    if code
      error = Lux::Error.new code
      error.message = message if message
      raise error
    else
      Lux::Error::AutoRaise
    end
  end

  # Quick response to page body
  # ```
  # response 'ok' if nav.root == 'healthcheck'
  # ```
  def response body=nil, status=nil
    return @current.response unless body

    response.status status || 200
    response.body body
    throw :done
  end

  # Tests current root against the string to get a mach.
  # Used by map function
  def test? route
    root = nav.root.to_s

    ok = case route
      when String
        root == route.sub(/^\//,'')
      when Symbol
        route.to_s == root
      when Regexp
        !!(route =~ root)
      when Array
        !!route.map(&:to_s).include?(root)
      else
        raise 'Route type %s is not supported' % route.class
    end

    nav.shift if ok

    ok
  end

  # Matches if there is not root in nav
  # Example calls MainController.action(:index) if in root
  # ```
  # root 'main#index'
  # ```
  def root target
    call target unless nav.root
  end

  # standard route match
  # match '/:city/people', Main::PeopleController
  def match base, target
    base = base.split('/').slice(1, 100)

    base.each_with_index do |el, i|
      if el[0,1] == ':'
        params[el.sub(':','').to_sym] = nav.path[i]
      else
        return unless el == nav.path[i]
      end
    end

    call target
  end

  @@namespaces ||= {}
  def self.namespace name, &block
    @@namespaces[name] = block
  end

  # Matches namespace block in a path
  # if returns true value, match is positive and nav is shifted
  # if given `Symbol`, it will call the function to do a match
  # if given `String`, it will match the string value
  # ```
  # self.namespace :city do
  #   @city = City.first slug: nav.root
  #   !!@city
  # end
  # namespace 'dashboard' do
  #   map orgs: 'dashboard/orgs'
  # end
  # ```
  def namespace name
    if String === name
      return unless test?(name.to_s)
    else
      if @@namespaces[name]
        return unless instance_exec &@@namespaces[name]
        nav.shift
      else
        raise ArgumentError.new('Namespace block :%s is not defined' % name)
      end
    end

    yield

    raise Lux::Error.not_found("Namespace <b>:#{name}</b> matched but nothing is called")
  end

  # Matches given subdomain name
  def subdomain name
    return unless nav.subdomain == name
    error.not_found 'Subdomain "%s" matched but nothing called' % name
  end

  # Main routing object, maps path part to target
  # if path part is positively matched with `test?` method, target is called with `call` method
  # ```
  # map api: ApiController
  # map api: 'api'
  # map [:api, ApiController]
  # map 'main/root' do
  # map [:login, :signup] => 'main/root'
  # map Main::RootController do
  #   map :about
  #   map '/verified-user'
  # end
  # ```
  def map route_object
    klass  = nil
    route  = nil
    action = nil

    # map 'root' do
    #   ...
    if block_given?
      @lux_action_target = route_object
      yield
      @lux_action_target = nil
      return
    elsif @lux_action_target
      klass  = @lux_action_target
      route  = route_object
      action = route_object

      # map :foo => :some_action
      if route_object.is_a?(Hash)
        route  = route_object.keys.first
        action = route_object.values.first
      end

      if test?(route)
        call klass, action
      else
        return
      end
    end

    case route_object
    when String
      # map 'root#call'
      call route_object
    when Hash
      route  = route_object.keys.first
      klass  = route_object.values.first

      if route.class == Array
        # map [:foo, :bar] => 'root'
        for route_action in route
          if test?(route_action)
            call klass, route_action
          end
        end

        return
      elsif route.is_a?(String) && route[0,1] == '/'
        # map '/skils/:skill' => 'main/skills#show'
        return match route, klass
      end
    when Array
      # map [:foo, 'main/root']
      route, klass = *route_object
    else
      Lux.error 'Unsupported route type "%s"' % route_object.class
    end

    test?(route) ? call(klass) : nil
  end

  # Calls target action in a controller, if no action is given, defaults to :index
  # ```
  # call :api_router
  # call proc { 'string' }
  # call proc { [400, {}, 'error: ...'] }
  # call [200, {}, ['ok']]
  # call Main::UsersController
  # call Main::UsersController, :index
  # call [Main::UsersController, :index]
  # call 'main/orgs#show'
  # ```
  def call object=nil, action=nil
    # log original app caller
    root    = Lux.root.join('app/').to_s
    sources = caller.select { |it| it.include?(root) }.map { |it| 'app/' + it.sub(root, '').split(':in').first }
    action  = action.gsub('-', '_').to_sym if action && action.is_a?(String)

    Lux.log ' Routed from: %s' % sources.join(' ') if sources.first

    case object
      when Symbol
        return send(object)
      when Hash
        object = [object.keys.first, object.values.first]
      when String
        object, action = object.split('#') if object.include?('#')
      when Array
        if object[0].class == Integer && object[1].class == Hash
          # [200, {}, 'ok']
          for key, value in object[1]
            response.header key, value
          end

          response.status object[0]
          response.body object[2]
        else
          object, action = object
        end
      when Proc
        case data = object.call
          when Array
            response.status = data.first
            response.body data[2]
          else
            response.body data
        end
    end

    throw :done if body?

    # figure our action unless defined
    unless action
      id =
      if respond_to?(:id?)
        nav.root { |root_id| id?(root_id) }
      else
        nav.root { |root_id| root_id.is_numeric? ? root_id.to_i : nil }
      end

      if id
        current.nav.id = id
        action = nav.shift || :show
      else
        action = nav.shift || :index
      end
    end

    object = ('%s_controller' % object).classify.constantize if object.is_a?(String)

    controller_name = "app/controllers/#{object.to_s.underscore}.rb"
    Lux.log ' %s' % controller_name
    current.files_in_use controller_name

    object.action action.to_sym

    unless response.body
      Lux.error 'Lux cell "%s" called via route "%s" but page body is not set' % [object, nav.root]
    end
  end

  # Action to do if there is an application error.
  # You want to overload this in a production.
  def on_error error
    raise error
  end

  def render
    Lux.log "\n#{current.request.request_method.white} #{current.request.url}"

    Lux::Config.live_require_check! if Lux.config(:auto_code_reload)

    main

    response.render
  end

  private

  # internall call to resolve the routes
  def main
    return if deliver_static_assets

    catch(:done) do
      class_callback :before
      class_callback :routes unless body?
    end

    catch(:done) do
      class_callback :after
    end
  rescue => e
    response.body { nil }

    catch(:done) do
      on_error(e)
    end
  end

  # Deliver static assets if `Lux.config.serve_static_files == true`
  def deliver_static_assets
    return if body? || !Lux.config(:serve_static_files)

    ext = request.path.split('.').last
    return unless ext.length > 1 && ext.length < 5
    file = Lux::Response::File.new request.path.sub('/', ''), inline: true
    file.send if file.is_static_file?
  end

end

