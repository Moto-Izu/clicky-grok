#!/usr/bin/env bash
# Install / re-sign / allow Gatekeeper-local / open privacy panes / launch Clicky (Grok).
# Usage:
#   bash scripts/install-and-launch-clicky.sh
#   bash scripts/install-and-launch-clicky.sh /path/to/Clicky.app

set -euo pipefail

APP_DEST="${CLICKY_APP_DEST:-/Applications/Clicky.app}"
BUNDLE_ID="local.motos.clicky-grok"
SRC_APP="${1:-}"

log() { printf '➜ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }

kill_existing() {
  killall Clicky 2>/dev/null || true
  sleep 0.4
}

resolve_source() {
  if [[ -n "$SRC_APP" && -d "$SRC_APP" ]]; then
    echo "$SRC_APP"
    return
  fi
  local candidates=(
    "/tmp/clicky-dd/Build/Products/Debug/Clicky.app"
    "/Users/motos/Documents/orca/clicky/build/Build/Products/Debug/Clicky.app"
    "$APP_DEST"
  )
  local c
  for c in "${candidates[@]}"; do
    if [[ -x "$c/Contents/MacOS/Clicky" ]]; then
      echo "$c"
      return
    fi
  done
  return 1
}

install_app() {
  local src="$1"
  if [[ "$(cd "$src" && pwd -P)" == "$(cd "$APP_DEST" 2>/dev/null && pwd -P || true)" ]]; then
    log "Already installed at $APP_DEST"
    return
  fi
  log "Installing $src → $APP_DEST"
  kill_existing
  rm -rf "$APP_DEST"
  ditto "$src" "$APP_DEST"
}

clear_quarantine_and_sign() {
  local app="$1"
  log "Clearing quarantine / extended attributes"
  xattr -cr "$app" 2>/dev/null || true
  # Some macOS builds only set provenance; still strip recursively.
  xattr -rd com.apple.quarantine "$app" 2>/dev/null || true

  log "Ad-hoc re-signing (deep)"
  # Sign nested frameworks first, then the app.
  if [[ -d "$app/Contents/Frameworks" ]]; then
    find "$app/Contents/Frameworks" -name "*.framework" -maxdepth 2 -type d 2>/dev/null | while read -r fw; do
      codesign --force --sign - --timestamp=none "$fw" 2>/dev/null || true
    done
    find "$app/Contents/Frameworks" -name "*.dylib" -type f 2>/dev/null | while read -r dylib; do
      codesign --force --sign - --timestamp=none "$dylib" 2>/dev/null || true
    done
  fi
  if [[ -d "$app/Contents/MacOS" ]]; then
    find "$app/Contents/MacOS" -name "*.dylib" -type f 2>/dev/null | while read -r dylib; do
      codesign --force --sign - --timestamp=none "$dylib" 2>/dev/null || true
    done
  fi

  local entitlements
  entitlements="$(mktemp -t clicky-ent.XXXXXX.plist)"
  cat >"$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <false/>
  <key>com.apple.security.network.client</key>
  <true/>
  <key>com.apple.security.device.audio-input</key>
  <true/>
  <key>com.apple.security.device.camera</key>
  <true/>
</dict>
</plist>
PLIST

  codesign --force --deep --sign - \
    --entitlements "$entitlements" \
    --timestamp=none \
    --options runtime=0 \
    "$app" 2>/dev/null \
    || codesign --force --deep --sign - --entitlements "$entitlements" --timestamp=none "$app"

  rm -f "$entitlements"

  log "Registering with Launch Services"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f -R -trusted "$app" 2>/dev/null || true

  codesign --verify --verbose=2 "$app" 2>&1 | head -5 || true
}

open_privacy_panes() {
  log "Opening System Settings privacy panes (grant when prompted)"
  # Microphone
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null \
    || open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone" 2>/dev/null \
    || true
  sleep 0.3
  # Accessibility
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null \
    || open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility" 2>/dev/null \
    || true
  sleep 0.3
  # Screen Recording
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null \
    || open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture" 2>/dev/null \
    || true
  sleep 0.3
  # Speech Recognition (Apple Speech path)
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition" 2>/dev/null \
    || open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SpeechRecognition" 2>/dev/null \
    || true
}

reset_tcc_for_bundle() {
  # Intentionally NO-OP by default.
  # Resetting TCC on every launch caused endless Grant loops (ad-hoc signature
  # + wiped permissions). Pass CLICKY_RESET_TCC=1 only when you really need it.
  if [[ "${CLICKY_RESET_TCC:-0}" != "1" ]]; then
    log "Skipping TCC reset (set CLICKY_RESET_TCC=1 to force)"
    return
  fi
  if command -v tccutil >/dev/null 2>&1; then
    log "Resetting TCC entries for $BUNDLE_ID (will re-prompt)"
    tccutil reset All "$BUNDLE_ID" 2>/dev/null || warn "tccutil reset skipped"
  fi
}

launch_app() {
  local app="$1"
  log "Launching $app"
  # Prefer open(1) so LaunchServices treats it as a proper app launch.
  open "$app" || {
    warn "open failed — launching binary directly"
    "$app/Contents/MacOS/Clicky" >/tmp/clicky-launch.out 2>/tmp/clicky-launch.err &
  }
  sleep 1.2
  if pgrep -x Clicky >/dev/null 2>&1; then
    log "Clicky is running (menu bar only — no Dock icon)."
    log "Look for the Clicky icon in the menu bar (top-right)."
    return 0
  fi
  warn "Process not detected. stderr:"
  cat /tmp/clicky-launch.err 2>/dev/null || true
  return 1
}

main() {
  local src
  if ! src="$(resolve_source)"; then
    warn "No Clicky.app found. Build first, then re-run."
    exit 1
  fi
  log "Source: $src"
  install_app "$src"
  clear_quarantine_and_sign "$APP_DEST"
  reset_tcc_for_bundle
  open_privacy_panes
  launch_app "$APP_DEST"

  cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next (one-time, manual switches):
  1. System Settings → Privacy & Security
  2. Enable for "Clicky":
     • Microphone
     • Accessibility
     • Screen & System Audio Recording
     • Speech Recognition
  3. Click the Clicky icon in the menu bar
  4. Tap "Sign in with xAI" for Grok OAuth

If Finder still blocks open:
  Right-click Clicky.app → Open → Open
  (or re-run this script)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
}

main "$@"
