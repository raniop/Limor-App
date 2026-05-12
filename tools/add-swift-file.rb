#!/usr/bin/env ruby
# encoding: UTF-8
# Adds a Swift source file to the Limor Ai App target.
#
# Usage:
#   ruby tools/add-swift-file.rb "Limor Ai App/Services/Foo.swift"
#
# Idempotent — re-running with the same path does nothing.

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require "xcodeproj"

PROJECT_PATH = File.expand_path(File.join(__dir__, "..", "Limor Ai App.xcodeproj"))
TARGET_NAME = "Limor Ai App"

source_path = ARGV[0]
abort "usage: add-swift-file.rb <path-to-swift-file>" unless source_path
abort "file not found: #{source_path}" unless File.exist?(source_path)

project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME }
abort "target '#{TARGET_NAME}' not found" unless target

# Project-root-relative path (e.g. "Limor Ai App/Services/Foo.swift").
rel_path = Pathname.new(File.expand_path(source_path))
             .relative_path_from(Pathname.new(File.dirname(PROJECT_PATH))).to_s

# Walk into the right group ("Limor Ai App" → "Services" → ...). We
# create groups along the way only when they don't already exist —
# matching Xcode's "Yellow Folder" convention.
parts = rel_path.split("/")
filename = parts.pop
group = project.main_group
parts.each do |segment|
  child = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == segment }
  group = child || group.new_group(segment, segment)
end

existing = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXFileReference) && c.display_name == filename }
if existing
  in_sources = target.source_build_phase.files_references.include?(existing)
  unless in_sources
    target.add_file_references([existing])
    puts "[add-swift-file] linked existing #{rel_path} into #{TARGET_NAME}"
  else
    puts "[add-swift-file] #{rel_path} already in #{TARGET_NAME} — nothing to do"
  end
else
  file_ref = group.new_reference(filename)
  target.add_file_references([file_ref])
  puts "[add-swift-file] added #{rel_path} to #{TARGET_NAME}"
end

project.save
