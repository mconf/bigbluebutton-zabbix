#!/usr/bin/ruby

require 'rubygems'
require 'find'
require 'pp'
require 'date'
require 'json'
require 'tzinfo'
require 'trollop'

def format_date_time(d)
  timezone = TZInfo::Timezone.get($tz)
  local_date = timezone.utc_to_local(d)
  local_date.strftime("%d/%m/%Y %H:%M:%S")
end

def get_dirs(record_id)
  output = Dir.glob("/var/bigbluebutton/published/*/#{record_id}/**/*")
  return output if ! output.empty?

  output = Dir.glob("/var/bigbluebutton/recording/raw/#{record_id}/**/*")
  return output if ! output.empty?

  output = []
  # presentations
  output += Dir.glob("/var/bigbluebutton/#{record_id}/**/*")
  # webcam streams in red5
  output += Dir.glob("/usr/share/red5/webapps/video/streams/#{record_id}/**/*")
  # screenshare streams in red5
  output += Dir.glob("/usr/share/red5/webapps/screenshare/streams/#{record_id}/**/*")
  # desktop sharing streams in red5
  output += Dir.glob("/var/bigbluebutton/deskshare/#{record_id}-*.flv")
  # FreeSWITCH wav recordings
  output += Dir.glob("/var/freeswitch/meetings/#{record_id}-*.wav")
  # webcam streams in kurento
  output += Dir.glob("/var/kurento/recordings/#{record_id}/**/*")
  # screenshare streams in kurento
  output += Dir.glob("/var/kurento/screenshare/#{record_id}/**/*")
  output
end

def get_size(record_id)
  size = 0
  get_dirs(record_id).each { |f| size += File.size(f) if File.file?(f) }
  size
end

def new_record()
  {
    "record_id" => nil,
    "meeting_name" => nil,
    "start_meeting" => nil,
    "end_meeting" => nil,
    "end_sanity" => nil,
    "end_publish" => nil,
    "record" => false,
    "status" => nil
  }
end

def assign_next(line, recordings, symbol, re, date_format)
  if (m = re.match line)
    date = DateTime.strptime(m[:date].to_s, date_format)
    if symbol == "restart_server"
      recordings.values.select{ |r| r["end_meeting"].nil? }.each do |r|
        r["end_meeting"] = date
        r["end_meeting_event"] = "server_restart"
        r["end_meeting_reason"] = "bbb-web restarted"
      end
    elsif m.names.include? "data"
      info = JSON.parse(m["data"])
      record_id = info["meetingId"]
      recordings[record_id] = new_record if ! recordings.has_key?(record_id)
      recordings[record_id]["record_id"] = record_id
      if info["event"] == "meeting_started"
        recordings[record_id]["meeting_name"] = info["name"]
        recordings[record_id]["record"] = info["record"]
      end
      if symbol == "end_meeting" && ! recordings[record_id].has_key?("end_meeting_event")
        recordings[record_id]["end_meeting_event"] = info["event"]
        recordings[record_id]["end_meeting_reason"] = info["description"]
      end
      recordings[record_id][symbol] = date
    else
      record_id = m["record_id"]
      recordings[record_id][symbol] = date if recordings.has_key?(record_id)
    end
    true
  else
    false
  end
end

recordings = {}

date_format = "%Y-%m-%dT%H:%M:%S.%L%:z"
`ls -tr1 /var/log/bigbluebutton/bbb-web.log* | xargs -I{} zgrep 'Meeting started\\|Removing expired meeting\\|Meeting ended\\|Removing un-joined meeting\\|Meeting destroyed\\|Starting Meeting Service' {}`.split("\n").each do |line|
  next if assign_next(line, recordings, "start_meeting", /(?<date>\d+-\d+-\d+.\d+:\d+:\d+\.\d+[^ ]*).*Meeting started: data=(?<data>.*)/i, date_format)
  next if assign_next(line, recordings, "end_meeting", /(?<date>\d+-\d+-\d+.\d+:\d+:\d+\.\d+[^ ]*).*(Meeting ended|Removing expired meeting|Removing un-joined meeting|Meeting destroyed): data=(?<data>.*)/i, date_format)
  next if assign_next(line, recordings, "restart_server", /(?<date>\d+-\d+-\d+.\d+:\d+:\d+\.\d+[^ ]*).*Starting Meeting Service.$/i, date_format)
end

date_format = "%Y-%m-%dT%H:%M:%S.%L"
if ! Dir.glob("/var/log/bigbluebutton/bbb-rap-worker.log*").empty?
  `ls -tr1 /var/log/bigbluebutton/bbb-rap-worker.log* | xargs -I{} zgrep 'Successfully sanity checked\\|Successfully archived\\|Publish format.*succeeded' {}`.split("\n").each do |line|
    next if assign_next(line, recordings, "end_sanity", /\[(?<date>\d+-\d+-\d+.\d+:\d+:\d+\.\d+).*Successfully sanity checked (?<record_id>\w+-\d+)/i, date_format)
    next if assign_next(line, recordings, "end_archive", /\[(?<date>\d+-\d+-\d+.\d+:\d+:\d+\.\d+).*Successfully archived (?<record_id>\w+-\d+)/i, date_format)
    next if assign_next(line, recordings, "end_publish", /\[(?<date>\d+-\d+-\d+.\d+:\d+:\d+\.\d+).*Publish format (?<format>[^ ]*) succeeded for (?<record_id>\w+-\d+)/i, date_format)
  end
end

recordings.each do |record_id, info|
  if info["end_meeting"].nil?
    info["status"] = "running"
  elsif ! info["record"] || info["end_meeting_reason"] == "Meeting has not been joined."
    info["status"] = "not recorded"
  elsif info["end_meeting_event"] == "server_restart"
    info["status"] = "server restarted"
  elsif ! info["end_publish"].nil?
    info["status"] = "processed"
  elsif File.exists?("/var/bigbluebutton/recording/status/published/#{record_id}-presentation.done")
    info["end_publish"] = DateTime.parse(File.mtime("/var/bigbluebutton/recording/status/published/#{record_id}-presentation.done").to_s)
    info["status"] = "processed"
  elsif `find /var/bigbluebutton/recording/status -name "*#{record_id}*" | wc -l`.strip.to_i == 0
    info["status"] = "deleted"
  elsif ! info["end_sanity"].nil?
    info["status"] = "processing"
  elsif File.exists?("/var/bigbluebutton/recording/status/archived/#{record_id}.norecord")
    info["status"] = "no recorded segment"
  elsif ! info["end_archive"].nil? && ! File.exists?("/var/bigbluebutton/recording/status/archived/#{record_id}.done")
    info["status"] = "no recorded segment removed"
  else
    info["status"] = "ended"
  end
end

class Array
  def average
    inject(&:+) / size
  end
end

opts = Trollop::options do
  opt :tz, "Timezone, check https://en.wikipedia.org/wiki/List_of_tz_database_time_zones", :default => "America/Sao_Paulo"
end

$tz = opts[:tz]
recordings = recordings.values

filtered = recordings.select{ |e| ! e["end_publish"].nil? && ! e["end_sanity"].nil? }.map{ |e| ((e["end_publish"] - e["end_sanity"]) * 24 * 60).to_i }
if ! filtered.empty?
  m = filtered.average
  recordings.select{ |e| e["end_publish"].nil? && ! e["end_sanity"].nil? }.each { |e| e["end_publish"] = e["end_sanity"] + m / (24 * 60).to_f }
end
now = DateTime.now
# time limit in minutes
time_limit = 60
recordings.reject! do |e|
  ( e["status"] == "processed" && ((now - e["end_publish"]) * 24 * 60).to_i > time_limit ) || \
  ( ["not recorded", "no recorded segment", "server restarted", "deleted"].include?(e["status"]) && ((now - e["end_meeting"]) * 24 * 60).to_i > time_limit ) || \
  ( e["status"] == "no recorded segment removed" && ((now - e["end_archive"]) * 24 * 60).to_i > time_limit )
end
recordings.sort! { |a,b| a["start_meeting"] <=> b["start_meeting"] }
recordings.map! do |info|
  {
    "id" => info["record_id"],
    "name" => info["meeting_name"],
    "size" => (get_size(info["record_id"]).to_f / 1024 / 1024).round(1),
    "begin" => info["start_meeting"].nil? ? "" : format_date_time(info["start_meeting"]),
    "end" => info["end_meeting"].nil? ? "" : format_date_time(info["end_meeting"]),
    "publish" => info["end_publish"].nil? ? "" : format_date_time(info["end_publish"]),
    "status" => info["status"]
  }
end

puts recordings.to_json.gsub("},", "},\n ")

