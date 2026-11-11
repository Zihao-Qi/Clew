# Homebrew cask for Clew, from this repo as its own tap:
#   brew tap zihao-qi/clew https://github.com/Zihao-Qi/Clew
#   brew install --cask clew        (later: brew upgrade --cask clew)
# Bump `version` together with MARKETING_VERSION in project.yml, then push the tag
# v<version>; .github/workflows/release.yml builds and publishes the zip.
cask "clew" do
  version "1.2.0"
  # Releases are built by CI from the tag; the download is checked by HTTPS from GitHub.
  sha256 :no_check

  url "https://github.com/Zihao-Qi/Clew/releases/download/v#{version}/Clew-#{version}.zip"
  name "Clew"
  desc "Today's list in the menu bar: what's left, what's done"
  homepage "https://github.com/Zihao-Qi/Clew"

  depends_on macos: ">= :sonoma"

  app "Clew.app"

  # Only `brew uninstall --zap` removes your data; a plain uninstall keeps it.
  zap trash: "~/Library/Containers/io.github.zihao-qi.clew"
end
