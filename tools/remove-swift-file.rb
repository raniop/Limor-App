#!/usr/bin/env ruby
# encoding: UTF-8
# Removes a Swift source file reference from the Xcode project (and
# from every target's Sources build phase that references it).
#
# Usage:
#   ruby tools/remove-swift-file.rb "Limor Ai App Watch/WatchVoiceService.swift"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require "xcodeproj"

PROJECT_PATH = File.expand_path(File.join(__dir__, "..", "Limor Ai App.xcodeproj"))

rel_path = ARGV[0]
abort "usage: remove-swift-file.rb <path>" unless rel_path

project = Xcodeproj::Project.open(PROJECT_PATH)
basename = File.basename(rel_path)

removed_count = 0
project.files.select { |f| f.display_name == basename }.each do |file_ref|
  file_ref.remove_from_project
  removed_count += 1
end

project.save
puts "[remove-swift-file] removed #{removed_count} reference(s) to #{basename}"
