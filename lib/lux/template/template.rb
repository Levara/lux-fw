# frozen_string_literal: true
require 'thread'

class Lux::Template
  @@template_cache = {}

  class << self
    def render_with_layout layout, template, helper={}
      part_data = new(template, helper).render_part

      Lux::Template.new(layout, helper).render_part { part_data }
    end

    def render_part template, helper={}
      new(template, helper).render_part
    end
  end

  def initialize template, context={}
    template           = template.sub(/^[^\w]+/, '')
    @original_template = template

    @helper = if context.class == Hash
      # create helper class if only hash given
      Lux::Helper.new(context)
    else
      context
    end

    mutex = Mutex.new

    if Lux.config(:auto_code_reload) && !Lux.thread[:template_cache]
      Lux.thread[:template_cache] = true
      mutex.synchronize { @@template_cache = {} }
    end

    if ref = @@template_cache[template]
      @tilt, @template = *ref
      return
    end

    for dir in ['./app/views']
      for ext in Tilt.default_mapping.template_map.keys
        next if @template
        test = "#{dir}/#{template}.#{ext}"
        @template = test if File.exists?(test)
      end
    end

    unless @template
      err = caller.reject{ |l| l =~ %r{(/lux/|/gems/)} }.map{ |l| el=l.to_s.split(Lux.root.to_s); el[1] || l }.join("\n")
      Lux.error %[Lux::Template "#{template}.{erb,haml}" not found\n\n#{err}]
    end

    begin
      mutex.synchronize do
        # @tilt = Tilt.new(@template, ugly:true, escape_html: false)
        @tilt = Tilt.new(@template, escape_html: false)
        @@template_cache[template] = [@tilt, @template]
      end
    rescue
      Lux.error("#{$!.message}\n\nTemplate: #{@template}")
    end
  end

  def render_part
    # global thread safe reference pointer to last temaplte rendered
    # we nned this for inline template render

    Lux.thread[:last_template_path] = @template.sub('/app/views','').sub(/\/[^\/]+$/,'').sub(/^\./,'')
    Lux.current.files_in_use @template

    data = nil

    speed = Lux.speed do
      begin
        data = @tilt.render(@helper) do
          yield if block_given?
        end
      rescue
        data = Lux::Error.inline %[Lux::Template #{@template} render error]
      end
    end

    Lux.log " app/views/#{@template.split('app/views/').last}, #{speed}"

    data
  end

end


