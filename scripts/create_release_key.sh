#!/usr/bin/env bash
# One-time setup of the Android release key.
#
# Creates the keystore that signs every OneLM release (outside the repository)
# and stores it in the GitHub Actions secrets used by the Android and Release
# workflows. With the GitHub CLI (`gh auth login` done) the secrets are set
# for you; without it the script prints what to paste in
# Settings > Secrets and variables > Actions.
#
#   bash scripts/create_release_key.sh [keystore path]
#
# Keep a backup of the keystore and its password (e.g. in a password
# manager): every future update must be signed with this same key, or phones
# refuse to install it over the old app.
set -euo pipefail

repo="FRFAL99/cross-platform-llm-client"
alias_name="privatelm"
keystore="${1:-$HOME/onelm-release.jks}"

find_keytool() {
  if command -v keytool >/dev/null 2>&1; then command -v keytool; return; fi
  for candidate in \
    "${JAVA_HOME:-}/bin/keytool" \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool" \
    "/c/Program Files/Android/Android Studio/jbr/bin/keytool.exe" \
    "$HOME/android-studio/jbr/bin/keytool" \
    "/opt/android-studio/jbr/bin/keytool"; do
    if [ -x "$candidate" ]; then echo "$candidate"; return; fi
  done
  return 1
}

keytool_bin=$(find_keytool) || {
  echo "keytool not found. Install a JDK (or Android Studio) and run again." >&2
  exit 1
}

if [ -e "$keystore" ]; then
  echo "$keystore already exists: not overwriting it." >&2
  echo "Pass another path, or reuse it (see README, Releases)." >&2
  exit 1
fi

while true; do
  read -rsp "Keystore password (at least 8 characters): " password; echo
  read -rsp "Repeat it: " again; echo
  if [ "${#password}" -lt 8 ]; then echo "Too short."; continue; fi
  if [ "$password" != "$again" ]; then echo "They don't match."; continue; fi
  break
done

# PKCS12 keystores use one password for the store and the key.
"$keytool_bin" -genkeypair -v \
  -keystore "$keystore" -storetype PKCS12 \
  -alias "$alias_name" -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "CN=OneLM" \
  -storepass "$password" -keypass "$password" >/dev/null
chmod 600 "$keystore"
echo "Created $keystore"

keystore_base64=$(base64 < "$keystore" | tr -d '\n\r')

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  printf %s "$keystore_base64" | gh secret set ANDROID_KEYSTORE_BASE64 --repo "$repo"
  printf %s "$password" | gh secret set ANDROID_KEYSTORE_PASSWORD --repo "$repo"
  printf %s "$password" | gh secret set ANDROID_KEY_PASSWORD --repo "$repo"
  printf %s "$alias_name" | gh secret set ANDROID_KEY_ALIAS --repo "$repo"
  echo "GitHub secrets set on $repo."
else
  out="$keystore.base64.txt"
  printf %s "$keystore_base64" > "$out"
  chmod 600 "$out"
  cat <<EOF

GitHub CLI not available (or not logged in): add these four secrets by hand at
https://github.com/$repo/settings/secrets/actions

  ANDROID_KEYSTORE_BASE64   the whole content of $out
  ANDROID_KEYSTORE_PASSWORD the password you just chose
  ANDROID_KEY_PASSWORD      the same password
  ANDROID_KEY_ALIAS         $alias_name

Then delete $out.
EOF
fi

cat <<EOF

Back up $keystore and its password now (password manager, a USB stick).
Losing them means the next release can't update the installed app.
EOF
