#!/usr/bin/ruby

require 'net/http'
require 'nokogiri'
require 'trollop'
require 'digest/sha1'
require 'benchmark'

# Manage BBB properties such as server address and salt.
# These informations can be loaded from file (bigbluebutton.properties) or
# externally set (for instance, from command line).
class BBBProperties
  def self.load_properties_from_file()
      servlet_dir = File.exists?("/usr/share/bbb-web/WEB-INF/classes/bigbluebutton.properties") ? "/usr/share/bbb-web" : "/var/lib/tomcat7/webapps/bigbluebutton"
      @@properties = Hash[File.read("#{servlet_dir}/WEB-INF/classes/bigbluebutton.properties", :encoding => "ISO-8859-1:UTF-8").scan(/(.+?)=(.+)/)]
  end

  def self.load_properties_from_cli(server_url, salt)
    @@properties = Hash.new(0)
    @@properties['bigbluebutton.web.serverURL'] = server_url
    @@properties['securitySalt'] = salt
  end

  def self.server_url
    @@server_url ||= get_properties 'bigbluebutton.web.serverURL'
  end

  def self.security_salt
    @@security_salt ||= get_properties 'securitySalt'
  end

  def self.get_properties(property)
    begin
      @@properties[property]
    rescue Errno::ENOENT => errno
      puts "error: #{errno}"
      exit
    end
  end

  private_class_method :get_properties
end

# Build URIs to different resources available in the BBB server.
class URIBuilder
  def self.server_url=(server_url)
    @@server_url = server_url
  end

  def self.api_uri
    @@api_uri ||= build_uri "/bigbluebutton/api"
  end

  def self.demo_uri
    @@demo_uri ||= build_uri "/demo/demo1.jsp"
  end

  def self.client_uri
    @@client_uri ||= build_uri "client/conf/config.xml"
  end

  def self.api_method_uri(method)
    @@method_uri ||= get_security method do |params, checksum|
      "bigbluebutton/api/#{method}?#{params}&checksum=#{checksum}"
    end
  end

  def self.build_uri(path)
    begin
      URI::join(@@server_url, path)
    rescue ArgumentError => errno
      puts "error: #{errno}"
      exit
    end
  end

  def self.get_security(method)
    params = "random=#{rand(99999)}"
    checksum = Digest::SHA1.hexdigest "#{method}#{params}#{BBBProperties.security_salt}"
    build_uri yield(params, checksum)
  end

  private_class_method :build_uri, :get_security
end

# HTTP connection manager to retrieve informations from the BBB server.
class HTTPRequester
  attr_accessor :ssl_enabled

  def initialize(ssl_enabled = false)
    @ssl_enabled = ssl_enabled
  end

  def get_response(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = @ssl_enabled

    # It never raises an exception
    http.get(uri.request_uri)
  end

  def get_response_code(*args)
    get_response(*args).code
  end

  def is_responding?(service)
    case service
    when 'bbb'
      service_uri = URIBuilder.api_uri
    when 'demo'
      service_uri = URIBuilder.demo_uri
    when 'client'
      service_uri = URIBuilder.client_uri
    else
      'Invalid service'
    end

    get_response(service_uri).code == '200'
  end
end

# Format like:
# meetings: 1, participants: 4, sent_videos: 0, received_videos: 0, sent_audio: 0, received_audio: 1, meetings_list: ["NAME", "random-36448439", "Random Room"]
class DefaultFormatter
  def hash_to_s(hash)
    hash.map {|k, v| "#{k}: #{v}"}.join(", ")
  end
end

# Format like:
# Meetings: 0, Users: 0, User with audio: 0, User with video: 0|meetings=0;;;0; users=0;;;0; audios=0;;;0; videos=0;;;0;
# Further information about Nagios output style:
# https://nagios-plugins.org/doc/guidelines.html#AEN200
class NagiosFormatter
  def hash_to_s(hash)
    "Meetings: #{hash[:meetings]}, Users: #{hash[:participants]}, User with audio: #{hash[:sent_audio]}, User with video: #{hash[:sent_videos]}|meetings=#{hash[:meetings]};;;0; users=#{hash[:participants]};;;0; audios=#{hash[:sent_audio]};;;0; videos=#{hash[:sent_videos]};;;0; "
  end
end

# All monitored services need
# a HTTP requester to retrive data from BBB server, and
# a formatter to put the output in the desired format.
class MonitoredService
  def self.requester=(requester)
    @@requester = requester
  end

  def self.formatter=(formatter)
    @@formatter = formatter
  end
end

# Retrieve and process meetings information
class Meetings < MonitoredService
  def self.process_meetings
    # Meetings data can change between queries so it should be computed every time
    update_meetings

    meetings_hash = {:meetings => 0,
      :participants => 0,
      :sent_videos => 0,
      :received_videos => 0,
      :sent_audio => 0,
      :received_audio => 0,
      :meetings_list => []}
    unless @@meetings.empty?
      meetings_hash[:meetings] = @@meetings.length
      @@meetings.each do |meeting|
        if meeting.at_xpath('running').text == 'true'
          participant_count = Integer(meeting.at_xpath('participantCount').text)
          listener_count = Integer(meeting.at_xpath('listenerCount').text)
          voice_participant_count = Integer(meeting.at_xpath('voiceParticipantCount').text)
          video_count = Integer(meeting.at_xpath('videoCount').text)
          meeting_name = meeting.at_xpath('meetingName').text

          meetings_hash[:meetings_list] << meeting_name
          meetings_hash[:participants] += participant_count
          meetings_hash[:sent_videos] += video_count
          meetings_hash[:received_videos] += video_count * (participant_count - 1)
          meetings_hash[:sent_audio] += voice_participant_count
          meetings_hash[:received_audio] += listener_count
        end
      end
    end
    meetings_hash
  end

  def self.update_meetings
    uri = URIBuilder.api_method_uri 'getMeetings'
    doc = Nokogiri::XML(@@requester.get_response(uri).body)

    @@meetings = doc.xpath('//meeting')
  end

  def self.text
    @@formatter.hash_to_s process_meetings
  end

  private_class_method :process_meetings, :update_meetings
end

# Retrieve and process recordings information
class Recordings < MonitoredService
  def self.process_recordings
    update_recordings

    {:recordings => @@recordings.length, :response_time => @@time}
  end

  def self.update_recordings
    uri = URIBuilder.api_method_uri 'getRecordings'
    response = nil
    time = Benchmark.measure do
      response = @@requester.get_response(uri)
    end

    @@time = time.to_s[/\(\s*([\d.]*)\)/, 1]
    doc = Nokogiri::XML(response.body)
    @@recordings = doc.xpath('//recording')
  end

  def self.text
    @@formatter.hash_to_s process_recordings
  end

  private_class_method :process_recordings, :update_recordings
end

def parse_xml(data, xpath)
  doc = Nokogiri::XML(data.body)
  node = doc.at_xpath(xpath)

  if node.nil? then nil else node.text end
end

opts = Trollop::options do
  opt :bbb, "Get BigBlueButton API HTTP response code" # --bbb, default false
  opt :demo, "Get demo.jsp HTTP response code" # --demo, default false
  opt :client, "Get Mconf-Live version in config.xml" # --client, default false
  opt :meetings, "Get meetings statistics" # --meetings, default false
  opt :recordings, "Get recordings statistics" # --recordings, default false
  opt :nagios, "Enable Nagios-style output" # --nagios, default false
  opt :server, "Server address in format '<scheme://<addr>:<port>/bigbluebutton'", :type => :string # --host, default nil
  opt :salt, "Salt of BBB server", :type => :string # --salt, default nil
  opt :ssl, "Enable secure HTTP with SSL" # --ssl, default false
end

requester = HTTPRequester.new(opts[:ssl])

# If --nagios is used, output response in Nagios response,
# according to https://nagios-plugins.org/doc/guidelines.html#AEN200.
formatter = if opts[:nagios] then NagiosFormatter.new() else DefaultFormatter.new() end

# If server or salt are not passed as arguments,
# load properties from bigbluebutton.properties.
unless opts[:server] and opts[:salt]
  BBBProperties.load_properties_from_file
else
  BBBProperties.load_properties_from_cli(opts[:server], opts[:salt])
end

if BBBProperties.server_url =~ /^http[s]?:\/\//
  URIBuilder.server_url = BBBProperties.server_url
else
  URIBuilder.server_url = (opts[:ssl] ? "https://" : "http://") + BBBProperties.server_url
end

if opts[:bbb]
  puts requester.get_response_code(URIBuilder.api_uri)
elsif opts[:demo]
  puts requester.get_response_code(URIBuilder.demo_uri)
elsif opts[:client]
  # Parse before verifying if 'client' is responding?
  version = parse_xml(requester.get_response(URIBuilder.client_uri),
                      '/config/version')
  puts if requester.is_responding?('client') ? version :
    "error: #{get_response_code(URIBuilder.client_uri)}"
elsif opts[:meetings]
  Meetings.requester = requester
  Meetings.formatter = formatter
  puts Meetings.text
elsif opts[:recordings]
  Recordings.requester = requester
  Recordings.formatter = formatter
  puts Recordings.text
end
