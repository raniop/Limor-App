#!/usr/bin/env ruby
# encoding: UTF-8
# Adds an "Inject Git SHA" Run Script build phase to the Limor Ai App
# target. The script reads the current short commit hash and patches
# LIMOR_GIT_SHA into the bundled Info.plist at build time, so the
# Settings → version footer shows the actual commit instead of "dev".
#
# Idempotent — re-running the script doesn't add a duplicate phase.

# Ruby 2.6 on macOS defaults to US-ASCII for external strings, which
# blows up when xcodeproj reads project.pbxproj files that contain
# UTF-8 (Hebrew display names, signing identities with accents). Force
# UTF-8 for the whole process before requiring the gem.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

require "xcodeproj"

PROJECT_PATH = File.expand_path(File.join(__dir__, "..", "Limor Ai App.xcodeproj"))
TARGET_NAME = "Limor Ai App"
PHASE_NAME = "Inject Git SHA"

SHELL_SCRIPT = <<~SHELL
  # Stamp the current git SHA onto the bundled Info.plist so the
  # in-app version footer shows the actual commit instead of "dev".
  # Reads `git rev-parse` from SRCROOT (worktree-aware) and falls
  # back to "dev" if git isn't available. Errors are non-fatal —
  # version footer is a debugging aid, not something worth blocking
  # the whole build for. `|| true` keeps `set -e` from killing us
  # when both Add and Set fail (e.g. plist isn't writable in this
  # build phase ordering).
  GIT_SHA=$(git -C "${SRCROOT}" rev-parse --short HEAD 2>/dev/null || echo "dev")
  PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
  if [ -f "$PLIST" ]; then
    (/usr/libexec/PlistBuddy -c "Add :LIMOR_GIT_SHA string $GIT_SHA" "$PLIST" 2>/dev/null \\
      || /usr/libexec/PlistBuddy -c "Set :LIMOR_GIT_SHA $GIT_SHA" "$PLIST" 2>/dev/null) || true
    echo "[inject-git-sha] LIMOR_GIT_SHA=$GIT_SHA → $PLIST"
  fi
  exit 0
SHELL

project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME }
abort "target '#{TARGET_NAME}' not found" unless target

existing = target.build_phases.find do |phase|
  phase.respond_to?(:name) && phase.name == PHASE_NAME
end

if existing
  existing.shell_script = SHELL_SCRIPT
  puts "[inject-git-sha] updated existing build phase"
else
  phase = target.new_shell_script_build_phase(PHASE_NAME)
  phase.shell_script = SHELL_SCRIPT
  # Run AFTER "Copy Bundle Resources" so the Info.plist is already
  # in BUILT_PRODUCTS_DIR by the time we patch it.
  puts "[inject-git-sha] added new build phase"
end

# Xcode 15+ sandboxes Run Script phases by default, which blocks our
# `git rev-parse` call. Turn the sandbox off on every config of this
# target — we're running locally-known commands (git + PlistBuddy)
# against project-local paths, nothing that needs the extra
# protection.
target.build_configurations.each do |config|
  config.build_settings["ENABLE_USER_SCRIPT_SANDBOXING"] = "NO"
end

project.save
puts "[inject-git-sha] saved project"
