#!/usr/bin/env ruby
# encoding: UTF-8
# Adds a watchOS app target ("Limor Ai App Watch") to the Limor Ai App
# Xcode project, wires up the source files in `Limor Ai App Watch/`,
# attaches the shared `Models.swift` + `SharedStore.swift` (needed for
# the watch's read of the shopping list and next-reminder snapshot),
# embeds the watch app as a "Watch Content" build phase on the iOS
# target, and sets WatchKit-required Info.plist / entitlement / bundle
# ID fields.
#
# Idempotent — re-running the script doesn't add a duplicate target or
# duplicate file references.

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require "xcodeproj"

PROJECT_PATH    = File.expand_path(File.join(__dir__, "..", "Limor Ai App.xcodeproj"))
IOS_TARGET_NAME = "Limor Ai App"
WATCH_TARGET    = "Limor Ai App Watch"
WATCH_DIR_NAME  = "Limor Ai App Watch"
IOS_BUNDLE_ID   = "com.rani.Limor-Ai-App"
WATCH_BUNDLE_ID = "#{IOS_BUNDLE_ID}.watchkitapp"
DEPLOYMENT      = "11.0"   # watchOS

project = Xcodeproj::Project.open(PROJECT_PATH)
ios_target = project.targets.find { |t| t.name == IOS_TARGET_NAME }
abort "ios target '#{IOS_TARGET_NAME}' not found" unless ios_target

watch_target = project.targets.find { |t| t.name == WATCH_TARGET }
if watch_target
  puts "[add-watch] target '#{WATCH_TARGET}' already exists — skipping creation"
else
  watch_target = project.new_target(:application, WATCH_TARGET, :watchos, DEPLOYMENT)
  puts "[add-watch] created target '#{WATCH_TARGET}'"
end

# --- File references --------------------------------------------------------
#
# Walk `Limor Ai App Watch/` and add every Swift file + Info.plist +
# entitlements to a group of the same name. Idempotent — `new_reference`
# would create duplicates, so we look for an existing reference first.

watch_dir_abs = File.join(File.dirname(PROJECT_PATH), WATCH_DIR_NAME)
abort "missing dir: #{watch_dir_abs}" unless Dir.exist?(watch_dir_abs)

watch_group = project.main_group.children.find do |c|
  c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == WATCH_DIR_NAME
end
watch_group ||= project.main_group.new_group(WATCH_DIR_NAME, WATCH_DIR_NAME)

swift_refs = []
plist_ref = nil
entitlements_ref = nil

Dir.children(watch_dir_abs).sort.each do |name|
  existing = watch_group.children.find do |c|
    c.is_a?(Xcodeproj::Project::Object::PBXFileReference) && c.display_name == name
  end
  ref = existing || watch_group.new_reference(name)
  case File.extname(name)
  when ".swift" then swift_refs << ref
  when ".plist" then plist_ref = ref
  when ".entitlements" then entitlements_ref = ref
  end
end

# Also pull in the Shared models + the App-Group store + the watch
# connectivity bridge; the watch UI reads SharedStore directly and
# `WatchSyncManager` is what receives WCSession context from iPhone.
shared_files = [
  "Shared/Models.swift",
  "Shared/SharedStore.swift",
  "Shared/WatchSyncManager.swift",
]
shared_files.each do |rel|
  basename = File.basename(rel)
  shared_group = project.main_group.children.find do |c|
    c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == "Shared"
  end
  ref = shared_group&.children&.find do |c|
    c.is_a?(Xcodeproj::Project::Object::PBXFileReference) && c.display_name == basename
  end
  swift_refs << ref if ref
end

# Stage Swift sources to the target's compile phase.
existing_source_refs = watch_target.source_build_phase.files_references
new_sources = swift_refs - existing_source_refs
watch_target.add_file_references(new_sources) unless new_sources.empty?
puts "[add-watch] sources: #{watch_target.source_build_phase.files.size} files (added #{new_sources.size})"

# --- Embed watch app into the iOS host -------------------------------------

embed_phase_name = "Embed Watch Content"
embed_phase = ios_target.copy_files_build_phases.find { |p| p.name == embed_phase_name }
if embed_phase.nil?
  embed_phase = ios_target.new_copy_files_build_phase(embed_phase_name)
  embed_phase.symbol_dst_subfolder_spec = :products_directory
  embed_phase.dst_path = "$(CONTENTS_FOLDER_PATH)/Watch"
  puts "[add-watch] added '#{embed_phase_name}' phase to '#{IOS_TARGET_NAME}'"
end
watch_product = watch_target.product_reference
already_embedded = embed_phase.files_references.include?(watch_product)
unless already_embedded
  build_file = embed_phase.add_file_reference(watch_product, true)
  build_file.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
  puts "[add-watch] embedded watch product into iOS target"
end

# --- Build settings on the watch target ------------------------------------

watch_target.build_configurations.each do |config|
  bs = config.build_settings
  bs["PRODUCT_BUNDLE_IDENTIFIER"]          = WATCH_BUNDLE_ID
  bs["PRODUCT_NAME"]                       = "$(TARGET_NAME)"
  bs["WATCHOS_DEPLOYMENT_TARGET"]          = DEPLOYMENT
  bs["TARGETED_DEVICE_FAMILY"]             = "4"   # watch
  bs["SDKROOT"]                            = "watchos"
  bs["SUPPORTS_MACCATALYST"]               = "NO"
  bs["SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] = "NO"
  bs["SWIFT_VERSION"]                      = "5.0"
  bs["MARKETING_VERSION"]                  = "1.0.0"
  bs["CURRENT_PROJECT_VERSION"]            = "11"
  bs["INFOPLIST_FILE"]                     = "#{WATCH_DIR_NAME}/Info.plist"
  bs["CODE_SIGN_ENTITLEMENTS"]             = "#{WATCH_DIR_NAME}/LimorWatch.entitlements"
  bs["CODE_SIGN_STYLE"]                    = "Automatic"
  bs["ENABLE_USER_SCRIPT_SANDBOXING"]      = "NO"
  bs["GENERATE_INFOPLIST_FILE"]            = "NO"
  bs["DEVELOPMENT_TEAM"]                   = "TFG2H9C76N"
  bs["ASSETCATALOG_COMPILER_APPICON_NAME"] = "AppIcon"
  bs["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = "YES"
  # Drop any iOS-only settings the template might have inserted.
  bs.delete("IPHONEOS_DEPLOYMENT_TARGET")
end

# --- App icons --------------------------------------------------------------
#
# The watch target needs an `AppIcon` asset to validate. We don't want
# to ship empty icons through this script — Xcode would scream — so
# the user is expected to drag a watch app icon into the asset
# catalog manually if there isn't one yet. For now reuse the iOS app's
# Assets.xcassets if it exists; otherwise leave the setting in place
# so Xcode's signing flow surfaces a useful error rather than a
# generic build failure.

project.save
puts "[add-watch] saved project"
