#!/usr/bin/env ruby
# encoding: UTF-8
# Adds `Limor Ai App Watch/Assets.xcassets` to the Watch target's
# resources phase so the AppIcon + AccentColor compile into the watch
# bundle. Idempotent.

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require "xcodeproj"

PROJECT_PATH = File.expand_path(File.join(__dir__, "..", "Limor Ai App.xcodeproj"))
TARGET_NAME  = "Limor Ai App Watch"
ASSET_REL    = "Limor Ai App Watch/Assets.xcassets"

project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME }
abort "target '#{TARGET_NAME}' not found" unless target

watch_group = project.main_group.children.find do |c|
  c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == "Limor Ai App Watch"
end
abort "watch group not found" unless watch_group

existing = watch_group.children.find do |c|
  c.is_a?(Xcodeproj::Project::Object::PBXFileReference) && c.display_name == "Assets.xcassets"
end
ref = existing || watch_group.new_reference(ASSET_REL)
# Xcode's default path for a new_reference is the relative path; the
# build needs it explicitly named so it lands in the right group.
ref.set_path("Assets.xcassets") if existing.nil?

already_added = target.resources_build_phase.files_references.include?(ref)
unless already_added
  target.add_resources([ref])
  puts "[add-watch-assets] linked Assets.xcassets into resources phase"
else
  puts "[add-watch-assets] already linked"
end

project.save
puts "[add-watch-assets] saved"
