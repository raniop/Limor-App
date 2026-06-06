#!/usr/bin/env ruby
# Adds the LimorShareExtension target to "Limor Ai App.xcodeproj".
#
# Idempotent: re-running with the target already present is a no-op.
# Run with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` so the xcodeproj gem's
# UTF-8-naive plist scanner doesn't choke on the project's non-ASCII strings.

require 'xcodeproj'

PROJECT_PATH = 'Limor Ai App.xcodeproj'
EXT_NAME     = 'LimorShareExtension'
EXT_BUNDLE   = 'com.rani.Limor-Ai-App.share'
EXT_DIR      = 'LimorShareExtension'

project = Xcodeproj::Project.open(PROJECT_PATH)

main_target = project.targets.find { |t| t.name == 'Limor Ai App' } \
  or abort "Main target 'Limor Ai App' not found"

main_group   = project.main_group
shared_group = main_group.children.find { |c| c.display_name == 'Shared' } \
  or abort "Shared group not found"

# ---------------------------------------------------------------------------
# 1. Make sure shared cross-target files exist in the project graph and are
#    compiled by the main app target. Same files get added to the extension
#    target's compile sources later.
# ---------------------------------------------------------------------------
def ensure_shared_file(group, name, main_target)
  ref = group.children.find { |f| f.display_name == name }
  if ref.nil?
    ref = group.new_reference(name)
    ref.last_known_file_type = 'sourcecode.swift'
    puts "Added Shared/#{name} to project graph"
  end
  unless main_target.source_build_phase.files_references.include?(ref)
    main_target.source_build_phase.add_file_reference(ref)
    puts "Added #{name} to '#{main_target.name}' compile sources"
  end
  ref
end

share_inbox_ref  = ensure_shared_file(shared_group, 'ShareInbox.swift',  main_target)
share_api_ref    = ensure_shared_file(shared_group, 'ShareAPI.swift',    main_target)
user_gender_ref  = ensure_shared_file(shared_group, 'UserGender.swift',  main_target)

# ---------------------------------------------------------------------------
# 2. Group + file references for the extension's own source files.
# ---------------------------------------------------------------------------
ext_group = main_group.children.find { |c| c.display_name == EXT_NAME }
if ext_group.nil?
  ext_group = main_group.new_group(EXT_NAME, EXT_DIR)
  puts "Created group '#{EXT_NAME}'"
end

def file_ref(group, name, file_type)
  ref = group.children.find { |f| f.display_name == name }
  return ref if ref
  ref = group.new_reference(name)
  ref.last_known_file_type = file_type
  ref
end

share_vc_ref      = file_ref(ext_group, 'ShareViewController.swift', 'sourcecode.swift')
info_plist_ref    = file_ref(ext_group, 'Info.plist',                'text.plist.xml')
entitlements_ref  = file_ref(ext_group, "#{EXT_NAME}.entitlements",  'text.plist.entitlements')

# ---------------------------------------------------------------------------
# 3. The target itself — app-extension product, share-services extension
#    point. Set after creation via NSExtensionPointIdentifier in Info.plist.
# ---------------------------------------------------------------------------
ext_target = project.targets.find { |t| t.name == EXT_NAME }
if ext_target.nil?
  ext_target = project.new_target(:app_extension, EXT_NAME, :ios, '18.0')
  puts "Created target '#{EXT_NAME}'"
end

ext_target.build_configurations.each do |config|
  config.build_settings.merge!(
    'PRODUCT_BUNDLE_IDENTIFIER'   => EXT_BUNDLE,
    'PRODUCT_NAME'                => '$(TARGET_NAME)',
    'INFOPLIST_FILE'              => "#{EXT_DIR}/Info.plist",
    'CODE_SIGN_ENTITLEMENTS'      => "#{EXT_DIR}/#{EXT_NAME}.entitlements",
    'IPHONEOS_DEPLOYMENT_TARGET'  => '18.0',
    'TARGETED_DEVICE_FAMILY'      => '1',
    'SWIFT_EMIT_LOC_STRINGS'      => 'YES',
    'SKIP_INSTALL'                => 'YES',
    'CODE_SIGN_STYLE'             => 'Automatic',
    'GENERATE_INFOPLIST_FILE'     => 'NO',
    'LD_RUNPATH_SEARCH_PATHS'     => [
      '$(inherited)',
      '@executable_path/Frameworks',
      '@executable_path/../../Frameworks',
    ],
    'CURRENT_PROJECT_VERSION'     => '$(CURRENT_PROJECT_VERSION)',
    'MARKETING_VERSION'           => '$(MARKETING_VERSION)',
  )
end

# ---------------------------------------------------------------------------
# 4. Compile sources for the extension. Both ShareViewController.swift and
#    the cross-target ShareInbox.swift need to be in this target's sources.
# ---------------------------------------------------------------------------
[share_vc_ref, share_inbox_ref, share_api_ref, user_gender_ref].each do |ref|
  next if ext_target.source_build_phase.files_references.include?(ref)
  ext_target.source_build_phase.add_file_reference(ref)
end

# ---------------------------------------------------------------------------
# 5. Dependency + embed phase, so building the main app also builds + bundles
#    the extension.
# ---------------------------------------------------------------------------
unless main_target.dependencies.any? { |d| d.target == ext_target }
  main_target.add_dependency(ext_target)
  puts "Added '#{EXT_NAME}' as dependency of '#{main_target.name}'"
end

embed_phase = main_target.copy_files_build_phases.find do |ph|
  ph.dst_subfolder_spec == '13' || ph.name == 'Embed Foundation Extensions'
end
if embed_phase.nil?
  embed_phase = main_target.new_copy_files_build_phase('Embed Foundation Extensions')
  embed_phase.dst_subfolder_spec = '13' # PlugIns
  embed_phase.dst_path = ''
  puts "Created 'Embed Foundation Extensions' phase"
end

unless embed_phase.files_references.include?(ext_target.product_reference)
  build_file = embed_phase.add_file_reference(ext_target.product_reference)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
  puts "Embedded '#{ext_target.product_reference.display_name}' in main app"
end

# ---------------------------------------------------------------------------
# 6. Make sure Info.plist + entitlements are visible in the file navigator
#    but not added to any compile/copy phase (they're referenced by build
#    settings, not by build phases).
# ---------------------------------------------------------------------------
# No build-phase membership needed for these; the group reference is enough.

project.save
puts "Saved #{PROJECT_PATH}"
