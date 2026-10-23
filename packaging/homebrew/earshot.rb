# Formula for a personal tap (knQzx/homebrew-tap), not for homebrew/core or homebrew/cask.
# It builds from source, so no notarization is needed. See RELEASING.md for the steps.
class Earshot < Formula
  desc "Shows your Claude Code terminal sessions in the MacBook notch"
  homepage "https://github.com/knQzx/earshot"
  url "https://github.com/knQzx/earshot/archive/refs/tags/v0.1.0.tar.gz"
  # PLACEHOLDER: replace with the SHA-256 of the v0.1.0 tarball after the tag exists:
  #   curl -sL https://github.com/knQzx/earshot/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/knQzx/earshot.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    ENV["SWIFT_FLAGS"] = "--disable-sandbox"
    system "scripts/bundle.sh", "release"
    prefix.install "build/Earshot.app"
    bin.install_symlink prefix/"Earshot.app/Contents/MacOS/earshot-hook"
  end

  def caveats
    <<~EOS
      Earshot lives in the notch, so copy it to your Applications folder and
      connect it to Claude Code once:

        mkdir -p ~/Applications
        rm -rf ~/Applications/Earshot.app
        cp -R #{opt_prefix}/Earshot.app ~/Applications/
        open ~/Applications/Earshot.app
        ~/Applications/Earshot.app/Contents/MacOS/earshot-hook --install

      Instead of the last line you can click "Install hooks" in the panel, or
      install the Claude Code plugin:
        /plugin install earshot --marketplace knQzx/earshot

      Repeat the copy after `brew upgrade earshot`. Claude Code sessions that
      were already running pick up the hooks after a restart.

      To remove the hooks from ~/.claude/settings.json later:
        ~/Applications/Earshot.app/Contents/MacOS/earshot-hook --uninstall

      Earshot is unofficial and not affiliated with or endorsed by Anthropic.
    EOS
  end

  test do
    assert_path_exists prefix/"Earshot.app/Contents/MacOS/Earshot"
    assert_path_exists prefix/"Earshot.app/Contents/MacOS/earshot-hook"
    assert_match version.to_s, pipe_output("#{bin}/earshot-hook --version", "")
    system "codesign", "--verify", "--strict", prefix/"Earshot.app"
  end
end
