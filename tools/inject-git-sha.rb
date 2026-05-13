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
  # All failures are downgraded to a `warning:` line so Xcode
  # surfaces them in the build log without failing the build — the
  # footer is a debugging aid, not load-bearing.
  #
  # The previous version swallowed stderr unconditionally, so when
  # `git` wasn't on the build script's PATH (or `.git` wasn't
  # readable from inside a sandboxed phase) we silently wrote
  # "dev" and the user had no way to tell *why*. Now every failure
  # path echoes a `warning:` and the build log explains it.

  GIT_BIN=$(command -v git || true)
  if [ -z "$GIT_BIN" ] && [ -x /usr/bin/git ]; then
    GIT_BIN=/usr/bin/git
  fi

  if [ -z "$GIT_BIN" ]; then
    echo "warning: [inject-git-sha] git not found on PATH; falling back to 'dev'"
    GIT_SHA="dev"
  else
    GIT_OUT=$("$GIT_BIN" -C "${SRCROOT}" rev-parse --short HEAD 2>&1)
    GIT_RC=$?
    if [ $GIT_RC -ne 0 ]; then
      echo "warning: [inject-git-sha] git rev-parse failed (rc=$GIT_RC) at ${SRCROOT}: $GIT_OUT"
      GIT_SHA="dev"
    else
      GIT_SHA="$GIT_OUT"
    fi
  fi

  PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
  if [ ! -f "$PLIST" ]; then
    echo "warning: [inject-git-sha] plist not found at $PLIST — phase may be running before resource copy"
    exit 0
  fi

  if /usr/libexec/PlistBuddy -c "Print :LIMOR_GIT_SHA" "$PLIST" >/dev/null 2>&1; then
    PB_OUT=$(/usr/libexec/PlistBuddy -c "Set :LIMOR_GIT_SHA $GIT_SHA" "$PLIST" 2>&1) \\
      || echo "warning: [inject-git-sha] Set failed: $PB_OUT"
  else
    PB_OUT=$(/usr/libexec/PlistBuddy -c "Add :LIMOR_GIT_SHA string $GIT_SHA" "$PLIST" 2>&1) \\
      || echo "warning: [inject-git-sha] Add failed: $PB_OUT"
  fi

  echo "[inject-git-sha] LIMOR_GIT_SHA=$GIT_SHA → $PLIST"
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
