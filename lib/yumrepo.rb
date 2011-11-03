require 'rubygems'
require 'open-uri'
require 'nokogiri'
require 'net/https'
require 'zlib'
require 'benchmark'
require 'singleton'
require 'digest/md5'
require 'fileutils'
require 'logger'

module YumRepo

  VERSION = '0.1'

  def self.bench(msg)
    if defined? $yumrepo_perf_debug
      out = Benchmark.measure do
        yield
      end
      puts msg + out.to_s
    else
      yield
    end
  end

  class Settings
    include Singleton
    attr_accessor :cache_path, :cache_expire, :log_level
    attr_reader :cache_enabled

    def initialize
      @cache_path = "#{ENV['HOME']}/.yumrepo/cache/"
      # Cache expire in seconds
      @cache_expire = 3600
      @cache_enabled = false
      @initialized = false
      @log_level = :info
    end

    def log_level=(level)
      case level
      when :warn
        level = Logger::WARN
      when :debug
        level = Logger::DEBUG
      when :info
        level = Logger::INFO
      when :error
        level = Logger::ERROR
      when :fatal
        level = Logger::FATAL
      else
        level = Logger::DEBUG
      end
      log.level = level
    end

    def log
      @log ||= Logger.new($stdout)
    end

    def init
      if @initialized
        log.debug "Settings already initialized"
        return
      end
      log.debug "Initializing settings"
      @initialized = true
    end

    def cache_enabled=(enabled)
      @cache_enabled = enabled

      if @cache_enabled
        if not File.exist? @cache_path
          log.debug "Creating cache path #{@cache_path}"
          FileUtils.mkdir_p @cache_path
        else
          log.debug "Using cache path #{@cache_path}"
        end
      end
    end
  end

  class Repomd

    #
    # Rasises exception if can't retrieve repomd.xml
    #
    def initialize(url)
      @settings = Settings.instance
      @settings.init
      @url = url
      if @url =~ /\/repodata\/?/
        @url.gsub! '/repodata', ''
      end
      @url_digest = Digest::MD5.hexdigest(@url)
      @repomd_file = File.join(@settings.cache_path, @url_digest, 'repomd.xml')

      if File.exist?(@repomd_file) and @settings.cache_enabled
        @settings.log.debug "Using catched repomd.xml at #{@repomd_file}"
        f = open @repomd_file
      else
        @settings.log.debug "Fetching repomd.xml from #{@url}"
        f = open "#{@url}/repodata/repomd.xml"
        if @settings.cache_enabled
          FileUtils.mkdir_p File.join(@settings.cache_path, @url_digest)
          @settings.log.debug "Caching repomd.xml for #{@url} at #{@repomd_file}"
          File.open(File.join(@settings.cache_path, @url_digest, 'repomd.xml'), 'w') do |xml|
            xml.puts f.read
          end
          f = open(@repomd_file)
        end
      end
      @repomd = Nokogiri::XML(f)
    end

    def filelists
      fl = []
      @repomd.xpath("/xmlns:repomd/xmlns:data[@type=\"filelists\"]/xmlns:location").each do |f|
       fl << File.join(@url, f['href'])
      end
      fl
    end

    def primary
      pl = []
      @repomd.xpath("/xmlns:repomd/xmlns:data[@type=\"primary\"]/xmlns:location").each do |p|
        pl << File.join(@url, p['href'])
      end
      @primary_xml = File.join(@settings.cache_path, @url_digest, "primary.xml.gz")
      if File.exist?(@primary_xml) and @settings.cache_enabled
        @settings.log.debug "Using catched primary.xml.gz at #{@primary_xml}"
        f = open @primary_xml
      else
        @settings.log.debug "Fetching primary.xml.gz from #{pl.first}"
        f = open pl.first
        if @settings.cache_enabled
          FileUtils.mkdir_p File.join(@settings.cache_path, @url_digest)
          @settings.log.debug "Caching primary.xml.gz for #{@url} at #{@primary_xml}"
          File.open(@primary_xml, 'w') do |xml|
            xml.puts f.read
          end
        end
      end
      @primary_xml
    end

    def other
      pl = []
      @repomd.xpath("/xmlns:repomd/xmlns:data[@type=\"other\"]/xmlns:location").each do |p|
        pl << File.join(@url, p['href'])
      end
      @other_xml = File.join(@settings.cache_path, @url_digest, "other.xml.gz")
      if File.exist?(@other_xml) and @settings.cache_enabled
        @settings.log.debug "Using catched other.xml.gz at #{@other_xml}"
        f = open @other_xml
      else
        @settings.log.debug "Fetching other.xml.gz from #{pl.first}"
        f = open pl.first
        if @settings.cache_enabled
          FileUtils.mkdir_p File.join(@settings.cache_path, @url_digest)
          @settings.log.debug "Caching other.xml.gz for #{@url} at #{@other_xml}"
          File.open(@other_xml, 'w') do |xml|
            xml.puts f.read
          end
        end
      end
      @other_xml
    end
  end

  class PackageList

    def initialize(url)
      @url = url
      @xml_file = open(Repomd.new(url).primary)
    end

    def each
      all.each do |p|
        yield p
      end
    end

    def all
      buf = ''
      YumRepo.bench("Zlib::GzipReader.read") do
        buf = Zlib::GzipReader.new(@xml_file).read
      end

      packages = []
      YumRepo.bench("Building Package Objects") do
        d = Nokogiri::XML::Reader(buf)
        d.each do |n|
          if n.name == 'package' and not n.node_type == Nokogiri::XML::Reader::TYPE_END_ELEMENT
            packages << Package.new(n.outer_xml)
          end
        end
      end
      packages
    end
  end

  class Package
    def initialize(xml)
      @xml = xml
    end

    def doc
      @doc ||= Nokogiri::XML(@xml)
    end

    def name
      doc.xpath('/xmlns:package/xmlns:name').text.strip
    end

    def summary
      doc.xpath('/xmlns:package/xmlns:summary').text.strip
    end

    def description
      doc.xpath('/xmlns:package/xmlns:description').text.strip
    end

    def url
      doc.xpath('/xmlns:package/xmlns:url').text.strip
    end

    def location
      doc.xpath('/xmlns:package/xmlns:location/@href').text.strip
    end

    def version
      doc.xpath('/xmlns:package/xmlns:version/@ver').text.strip
    end

    def release
      doc.xpath('/xmlns:package/xmlns:version/@rel').text.strip
    end

    def src_rpm
      doc.xpath('/xmlns:package/xmlns:format/xmlns:sourcerpm').text.strip
    end

    def group
      doc.xpath('/xmlns:package/xmlns:format/rpm:group').text.strip
    end

    def vendor
      doc.xpath('/xmlns:package/xmlns:format/rpm:vendor').text.strip
    end

    def license
      doc.xpath('/xmlns:package/xmlns:format/rpm:license').text.strip
    end

    def provides
      doc.xpath('/xmlns:package/xmlns:format/rpm:provides/rpm:entry').map do |pr|
        {
          :name => pr.at_xpath('./@name').text.strip
        }
      end
    end

    def requires
      doc.xpath('/xmlns:package/xmlns:format/rpm:requires/rpm:entry').map do |pr|
        {
          :name => pr.at_xpath('./@name').text.strip
        }
      end
    end
  end


  class PackageChangelog
    @@version_regex_std = /(^|\:|\s+|v|r|V|R)(([0-9]+\.){1,10}[a-zA-Z0-9\-]+)/
    @@version_regex_odd = /(([a-zA-Z0-9\-]+)\-[a-zA-Z0-9\-]{1,10})/


    def initialize(xml)
      doc = Nokogiri::XML(@xml)
      puts doc.path
      doc.xpath('/xmlns:package/xmlns:format/rpm:requires/rpm:entry').map do |pr|
        {
          :name => pr.at_xpath('./@name').text.strip
        }
      end
    end

    private

    def _get_version_string(input)
      m = @@version_regex_std.match(input)
      return m[2].to_s.strip() if m

      m = @@version_regex_odd.match(input)
      return m[1].to_s.strip() if m
    end

  end

  class Release
    @@version_regex_std = /(^|\:|\s+|v|r|V|R)(([0-9]+\.){1,10}[a-zA-Z0-9\-]+)/
    @@version_regex_odd = /(([a-zA-Z0-9\-]+)\-[a-zA-Z0-9\-]{1,10})/

    def initialize(xml)
      @xml = xml
    end

    def doc
      @doc ||= Nokogiri::XML(@xml)
    end

    def author
      doc.xpath('/xmlns:changelog/@author').text.strip
    end

    def summary
      doc.xpath('/xmlns:changelog').text.strip
    end

    def date
      Time.at(doc.xpath('/xmlns:changelog/@date').text.strip)
    end

    def version
      m = @@version_regex_std.match(self.author)
      return m[2].to_s.strip() if m

      m = @@version_regex_odd.match(self.author)
      return m[1].to_s.strip() if m
    end
  end


end
