#!/usr/bin/ruby

require 'rubygems'

def format_latency(latency)
    m = latency.match(/(?<minutes>\d+)m(?<seconds>[0-9\.]+)s/)
    (m[:minutes].to_i * 60000 + m[:seconds].to_f * 1000).to_i
end

def latency(server)
    format_latency `bash -c "(time dig #{server} +trace) 2>&1"`.split("\n").select{ |line| line.start_with?("real") }.first.split()[1]
end

dns_servers = []
`which nmcli`
if $?.success?
    `nmcli dev show`.split("\n").select{ |line| line.start_with?("IP4.DNS") }.each do |line|
        dns_servers << line.split()[1]
    end
end

dns_servers << `nslookup google.com`.split("\n").select{ |line| line.start_with?("Server") }.first.split()[1]

dns_servers << "8.8.8.8"
dns_servers.uniq!

result = dns_servers.map{ |server| "#{server}=#{latency(server)}"}.join(" ")
puts result
