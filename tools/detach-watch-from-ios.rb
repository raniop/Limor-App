#!/usr/bin/env ruby
# encoding: UTF-8
# Removes the "Embed Watch Content" copy-files phase + the implicit
# target dependency that `add-watch-target.rb` set up. The iOS target
# can be built again without watchOS SDK installed. Run
# `add-watch-target.rb` once watchOS SDK is available to re-attach.

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require "xcodeproj"

PROJECT_PATH    = File.expand_path(File.join(__dir__, "..", "Limor Ai App.xcodeproj"))
IOS_TARGET_NAME = "Limor Ai App"
WATCH_TARGET    = "Limor Ai App Watch"

project = Xcodeproj::Project.open(PROJECT_PATH)
ios_target = project.targets.find { |t| t.name == IOS_TARGET_NAME }
watch_target = project.targets.find { |t| t.name == WATCH_TARGET }
abort "ios target missing" unless ios_target

# Drop the implicit dependency the embed phase added.
to_remove = ios_target.dependencies.select do |dep|
  dep.target == watch_target || dep.display_name == WATCH_TARGET
end
to_remove.each { |dep| dep.remove_from_project }
puts "[detach-watch] removed #{to_remove.size} target dependencies"

# Drop the "Embed Watch Content" phase entirely.
ios_target.copy_files_build_phases.dup.each do |phase|
  if phase.name == "Embed Watch Content"
    phase.remove_from_project
    puts "[detach-watch] removed embed phase"
  end
end

project.save
puts "[detach-watch] saved project"
