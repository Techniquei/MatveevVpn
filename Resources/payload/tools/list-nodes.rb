#!/usr/bin/env ruby

require "uri"

abort "usage: list-nodes.rb SUBSCRIPTION" unless ARGV.length == 1

File.readlines(ARGV[0], chomp: true).reject(&:empty?).each_with_index do |line, index|
  begin
    uri = URI.parse(line)
    next unless uri.scheme == "vless"
    label = URI.decode_www_form_component(uri.fragment.to_s)
    label = "#{uri.host}:#{uri.port}" if label.empty?
    puts "#{index + 1}\t#{label}"
  rescue URI::InvalidURIError
    next
  end
end
