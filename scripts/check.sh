#!/bin/zsh
# Pre-push checks run by `make check` (after tests and `make app`):
# the bundle is complete, and nothing secret or personal is about to be published.
set -u
cd "${0:A:h}/.."
fail=0
ok()  { print "ok    $1" }
bad() { print "FAIL  $1"; fail=1 }

# 1. Release bundle: plist valid, binary and every icon present.
app=build/AISubsUsage-MenuBar.app
plutil -lint -s packaging/Info.plist && ok "Info.plist is valid" || bad "Info.plist is invalid"
[[ -x $app/Contents/MacOS/AISubsUsageMenuBar ]] && ok "app binary built" || bad "app binary missing"
for f in AppIcon.icns claude.png figma.png openai.svg; do
  [[ -f $app/Contents/Resources/$f ]] || bad "bundle is missing Resources/$f"
done
ok "bundle resources checked"

# 2. Files that would be published (git-tracked, or all non-ignored files before the first commit).
if git rev-parse --git-dir >/dev/null 2>&1; then
  files=("${(@f)$(git ls-files --cached --others --exclude-standard)}")
else
  bad "not a git repository yet"; files=()
fi

# 3. Secrets: real-looking tokens or keys. The test vector "sk-ant-sid01-example" is fine.
secret='sk-ant-[A-Za-z0-9_-]{24,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}'
if (( ${#files} )) && hits=$(grep -nEI -- "$secret" "${files[@]}" 2>/dev/null); then
  bad "possible secrets:"; print -- "$hits"
else
  ok "no secrets found"
fi

# 4. Personal data: real email addresses (example.com is fine) and local paths.
personal='[A-Za-z0-9._%+-]+@(gmail|icloud|outlook|hotmail|yahoo|proton)\.[a-z]+|/Users/[a-z]+/'
if (( ${#files} )) && hits=$(grep -nEI -- "$personal" "${files[@]}" 2>/dev/null); then
  bad "possible personal data:"; print -- "$hits"
else
  ok "no personal data found"
fi

# 5. Build output must never be committed.
if (( ${#files} )) && print -l -- "${files[@]}" | grep -qE '^(\.build|build)/'; then
  bad "build output is tracked"
else
  ok "build output not tracked"
fi

exit $fail
