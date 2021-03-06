tick="✓"
cross="✗"

step_log() {
  message=$1
  printf "\n\033[90;1m==> \033[0m\033[37;1m%s\033[0m\n" "$message"
}

add_log() {
  mark=$1
  subject=$2
  message=$3
  if [ "$mark" = "$tick" ]; then
    printf "\033[32;1m%s \033[0m\033[34;1m%s \033[0m\033[90;1m%s\033[0m\n" "$mark" "$subject" "$message"
  else
    printf "\033[31;1m%s \033[0m\033[34;1m%s \033[0m\033[90;1m%s\033[0m\n" "$mark" "$subject" "$message"
  fi
}

message_version=$(echo "$GITHUB_MESSAGE" | grep -Eo 'build-only-[0-9].[0-9]' | cut -d '-' -f 3)
[ "$message_version" != "" ] && [ "$PHP_VERSION" != "php@$message_version" ] && exit 0;

if [[ "$PHP_VERSION" =~ php$|php@7.[2-3] ]] && [[ "$GITHUB_MESSAGE" != *--skip-fetch* ]]; then
  step_log "Sourcing latest formulae"
  mkdir -p Formula
  curl -o "Formula/$PHP_VERSION.rb" "https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/$PHP_VERSION.rb" >/dev/null 2>&1
  add_log "$tick" "Formulae" "Sourced"
fi

step_log "Checking label"
package="${PHP_VERSION//@/:}"
new_version=$(brew info Formula/"$PHP_VERSION".rb | grep "$PHP_VERSION" | head -n 1 | cut -d' ' -f3)
existing_version=$(curl --user "$HOMEBREW_BINTRAY_USER":"$HOMEBREW_BINTRAY_KEY" -s https://api.bintray.com/packages/"$HOMEBREW_BINTRAY_USER"/"$HOMEBREW_BINTRAY_REPO"/"$package" | sed -e 's/^.*"latest_version":"\([^"]*\)".*$/\1/' | cut -d '_' -f 1)
latest_version=$(printf "%s\n%s" "$new_version" "$existing_version" | sort | tail -n 1)
echo "existing label: $existing_version"
echo "new label: $new_version"

if [[ "$GITHUB_MESSAGE" = *--build-all* ]] || [ "$latest_version" != "$existing_version" ] || [[ "$new_version" =~ ^8.* ]]; then
  add_log "$tick" "PHP $new_version" "New label found or nightly build"

  step_log "Updating Homebrew"
  while read -r formula; do
    curl -o "$(brew --prefix)/Homebrew/Library/Taps/homebrew/homebrew-core/Formula/$formula.rb" -sL "https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/$formula.rb" &
    to_wait+=( $! )
  done < "./.github/deps/${ImageOS:?}_${ImageVersion:?}"
  wait "${to_wait[@]}"
  add_log "$tick" "Homebrew" "Updated"

  step_log "Adding tap $GITHUB_REPOSITORY"
  mkdir -p "$(brew --prefix)/Homebrew/Library/Taps/$HOMEBREW_BINTRAY_USER"
  ln -s "$PWD" "$(brew --prefix)/Homebrew/Library/Taps/$GITHUB_REPOSITORY"
  add_log "$tick" "$GITHUB_REPOSITORY" "Tap added to brewery"

  step_log "Filling the Bottle"
  if [ "$DARWIN_VERSION" = "macos-10.15" ]; then
    sudo xcode-select -s /Applications/Xcode_11.7.app
  else
    sudo xcode-select -s /Applications/Xcode_12.2.app
  fi
  brew test-bot "$HOMEBREW_BINTRAY_USER"/"$HOMEBREW_BINTRAY_REPO"/"$PHP_VERSION" --root-url="$HOMEBREW_BINTRAY_URL"
  LC_ALL=C find . -type f -name '*.json' -exec sed -i '' s~homebrew/bottles-php~"$HOMEBREW_BINTRAY_USER"/"$HOMEBREW_BINTRAY_REPO"~ {} +
  LC_ALL=C find . -type f -name '*.json' -exec sed -i '' s~bottles-php~php~ {} +
  LC_ALL=C find . -type f -name '*.json' -exec sed -i '' s~bottles~php~ {} +
  add_log "$tick" "PHP $new_version" "Bottle filled"

  step_log "Adding label"
  curl \
  --user "$HOMEBREW_BINTRAY_USER":"$HOMEBREW_BINTRAY_KEY" \
  --header "Content-Type: application/json" \
  --data " \
  {\"name\": \"$package\", \
  \"vcs_url\": \"$GITHUB_REPOSITORY\", \
  \"licenses\": [\"MIT\"], \
  \"public_download_numbers\": true, \
  \"public_stats\": true \
  }" \
  https://api.bintray.com/packages/"$HOMEBREW_BINTRAY_USER"/"$HOMEBREW_BINTRAY_REPO" >/dev/null 2>&1 || true
  add_log "$tick" "$package" "Bottle labeled"

  step_log "Stocking the new Bottle"
  if [ "$(find . -name '*.json' | wc -l 2>/dev/null | wc -l)" != "0" ]; then
    # curl --user "$HOMEBREW_BINTRAY_USER":"$HOMEBREW_BINTRAY_KEY" -X DELETE https://api.bintray.com/packages/"$HOMEBREW_BINTRAY_USER"/"$HOMEBREW_BINTRAY_REPO"/"$package"/versions/"$new_version" >/dev/null 2>&1 || true
    export HOMEBREW_BOTTLE_DOMAIN="https://dl.bintray.com/$HOMEBREW_BINTRAY_USER"
    brew test-bot --ci-upload --publish --tap="$GITHUB_REPOSITORY" --root-url="$HOMEBREW_BINTRAY_URL" --bintray-org="$HOMEBREW_BINTRAY_USER"    
    add_log "$tick" "PHP $new_version" "Bottle added to stock"

    step_log "Updating inventory"
    git config --local user.email homebrew-test-bot@lists.sfconservancy.org
    git config --local user.name BrewTestBot
    for try in $(seq 10); do
      echo "try: $try"
      git rebase --abort || true
      git
      git fetch origin master && git rebase origin/master
      if [ "$(git ls-files -u | wc -l)" -gt 0 ] ; then
        sed -i '' '/=====|>>>>>|<<<<</d' Formula/"$PHP_VERSION".rb
        git add Formula/"$PHP_VERSION".rb && git rebase --continue
      fi
      if git push https://"$GITHUB_REPOSITORY_OWNER":"$GITHUB_TOKEN"@github.com/"$GITHUB_REPOSITORY".git master; then
        break
      else
        sleep 3s
      fi
    done
    add_log "$tick" "Inventory" "updated"
    echo "::set-output name=build::true"
  else
    echo "::set-output name=build::false"
    add_log "$cross" "bottle" "broke"
    exit 1
  fi    
else
  echo "::set-output name=build::false"
  add_log "$tick" "PHP $new_version" "Bottle exists"
fi
