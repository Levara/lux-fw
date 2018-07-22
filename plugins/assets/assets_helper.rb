# export to all templates
# = asset 'www/index.scss'
# = asset 'www/index.coffee'
module HtmlHelper
  def asset_include path, opts={}
    raise ArgumentError.new("Path can't be empty") if path.empty?

    ext  = path.split('?').first.split('.').last
    type = ['css', 'sass', 'scss'].include?(ext) ? :style : :script
    type = :style if path.include?('fonts.googleapis.com')

    current.response.early_hints path, type

    if type == :style
      if opts[:minimalcss] && Lux.current.response.is_first?
        minimalcss = File.read('./public/assets/minimal-%s.css' % opts[:minimalcss]) rescue Lux.error('Assets: minimalcss "%s" not found' % opts[:minimalcss])
        %[<style>#{minimalcss}</style>\n<link rel="preload" as="style" href="#{path}" onload="this.rel='stylesheet'" />]
      else
        %[<link rel="stylesheet" href="#{path}" />]
      end
    else
      %[<script src="#{path}"></script>]
    end
  end

  # builds full asset path based on resource extension
  # asset('main/index.coffee')
  # will render 'app/assets/main/index.coffee' as http://aset.path/assets/main-index-md5hash.js
  def asset file, opts={}
    opts = { dev_file: opts } unless opts.class == Hash

    # return second link if it is defined and we are in dev mode
    return asset_include opts[:dev_file] if opts[:dev_file] && Lux.dev?

    # return internet links
    return asset_include file if file.starts_with?('/') || file.starts_with?('http')

    # return asset link in production or fail unless able
    unless Lux.config(:compile_assets)
      manifest = Lux.ram_cache('asset-manigest') { JSON.load Lux.root.join('public/manifest.json').read }
      mfile    = manifest['files'][file]

      raise 'Compiled asset link for "%s" not found in manifest.json' % file if mfile.empty?

      return asset_include(Lux.config.assets_root.to_s + mfile, opts)
    end

    # try to create list of incuded files and show every one of them
    data = []
    asset = SimpleAssets.new file

    for file in asset.dev_sources
      data.push asset_include '/compiled_asset/' + file
    end

    data.map{ |it| it.sub(/^\s\s/,'') }.join("\n")
  end
end