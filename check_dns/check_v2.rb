#!/usr/bin/ruby

require 'rubygems'

def format_latency(latency)
    m = latency.match(/(?<msec>\d+) msec/)
    m[:msec]
end

def format_server(server)
    m = server.match(/(?<ip>\d+.\d+.\d+.\d+).*/)
    m[:ip]
end

output = `dig google.com`.split("\n")
if output.select{ |line| line.start_with?(";; ANSWER SECTION:") }.empty?
    puts "CRITICAL - Could not resolve google.com using local DNS server"
    exit 1
end

latency = format_latency output.select{ |line| line.start_with?(";; Query time:") }.first.split(":")[1].strip
server = format_server output.select{ |line| line.start_with?(";; SERVER:") }.first.split(":")[1].strip

puts "#{server}=#{latency}"
