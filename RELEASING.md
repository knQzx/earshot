# Releasing Earshot

The steps the maintainer runs for a release. Nothing here runs automatically except the release workflow, which starts when a `v*` tag is pushed. The examples use 0.1.0; replace it with the version you are releasing.

## 1. Before tagging

1. Make sure `main` is green in CI and your checkout is clean and up to date:

   ```sh
   git switch main
   git pull --ff-only
   git status
   ```

2. Set the version everywhere it appears. All of these must say the same thing:

   | File | What to change |
   |---|---|
   | `VERSION` | `0.1.0` (the release workflow checks it against the tag) |
   | `Sources/EarshotHook/main.swift` | the string printed by `--version` |
   | `plugin/.claude-plugin/plugin.json` | `"version"` |
   | `packaging/homebrew/earshot.rb` | the tag in `url` (the checksum comes later) |
   | `Resources/Info.plist` | optional, `scripts/bundle.sh` overwrites both version keys from `VERSION` |

   `git grep -n "0\.1\.0"` lists them.

3. In `CHANGELOG.md`, change `## [0.1.0] - Unreleased` to today's date, for example `## [0.1.0] - 2026-11-02`. The release notes are taken from this section, so read it once more.

4. Check locally:

   ```sh
   make test
   make check-no-network
   UNIVERSAL=1 scripts/bundle.sh release
   codesign --verify --strict --verbose=2 build/Earshot.app
   lipo -archs build/Earshot.app/Contents/MacOS/Earshot
   lipo -archs build/Earshot.app/Contents/MacOS/earshot-hook
   echo -n | build/Earshot.app/Contents/MacOS/earshot-hook --version
   ```

5. If the screenshots are out of date, run `make snapshot` and commit `docs/media`.

6. Regenerate the README animation, `docs/media/preview.gif`, whenever the promo video changes. From a scratch folder, with the video at `~/Downloads/earshot-preview.mp4`:

   ```sh
   ffmpeg -i ~/Downloads/earshot-preview.mp4 \
     -vf "fps=10,scale=800:-1:flags=lanczos,palettegen=stats_mode=diff:max_colors=96" palette.png
   ffmpeg -i ~/Downloads/earshot-preview.mp4 -i palette.png \
     -lavfi "fps=10,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" preview.gif
   ls -l preview.gif   # keep it under about 8 MB
   cp preview.gif <repo>/docs/media/preview.gif
   ```

   If it comes out bigger, lower `max_colors` or cut the video to its best 10 to 12 seconds with `-ss` and `-t`. Check that the video only shows neutral sample names.

7. Commit the version bump:

   ```sh
   git commit -am "Earshot 0.1.0"
   git push origin main
   ```

## 2. Tag and let the workflow build

1. Create a signed, annotated tag and push it:

   ```sh
   git tag -s v0.1.0 -m "Earshot 0.1.0"
   git push origin v0.1.0
   ```

2. Watch `.github/workflows/release.yml` in the Actions tab. It:
   - fails if `VERSION` does not match the tag
   - runs `make test` and `make check-no-network`
   - builds a universal app with `UNIVERSAL=1 scripts/bundle.sh release` (ad-hoc signed, CI never uses a local identity)
   - zips it with `ditto -c -k --keepParent` as `Earshot-v0.1.0.zip` and writes `Earshot-v0.1.0.zip.sha256`
   - creates the GitHub release with the CHANGELOG section plus install and Gatekeeper notes

   If it fails before the release step, fix the problem on `main`, then move the tag:

   ```sh
   git tag -d v0.1.0
   git push origin :refs/tags/v0.1.0
   git tag -s v0.1.0 -m "Earshot 0.1.0"
   git push origin v0.1.0
   ```

3. Check the release page:
   - the zip and the `.sha256` file are attached
   - the notes read well
   - download the zip on a Mac, then:

     ```sh
     shasum -a 256 -c Earshot-v0.1.0.zip.sha256
     ditto -x -k Earshot-v0.1.0.zip /tmp/earshot-check
     codesign --verify --strict /tmp/earshot-check/Earshot.app
     ```

   - move it to `~/Applications` on a test account, confirm macOS blocks the first launch and that "Open Anyway" in System Settings > Privacy & Security works, then install the hooks and start a `claude` session

## 3. Homebrew tap

The formula lives in `packaging/homebrew/earshot.rb` and is meant for a personal tap, `knQzx/homebrew-tap`. homebrew/cask is not an option without notarization.

1. Get the checksum of the source tarball for the tag:

   ```sh
   curl -sL https://github.com/knQzx/earshot/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256
   ```

2. Put it into `sha256` in `packaging/homebrew/earshot.rb` (replacing the zeros and the PLACEHOLDER comment) and make sure `url` points at the same tag. Commit that on `main`.

3. Copy the formula to the tap repository as `Formula/earshot.rb`, commit and push there.

4. Check it on a Mac with Xcode:

   ```sh
   brew update
   brew install --build-from-source knQzx/tap/earshot
   brew test knQzx/tap/earshot
   brew audit --strict knQzx/tap/earshot
   brew uninstall earshot
   ```

## 4. Claude Code plugin

The repository is its own plugin marketplace (`.claude-plugin/marketplace.json`, plugin in `plugin/`). Users install from the default branch, so the plugin is live as soon as `main` has the new version.

1. Check that `plugin/.claude-plugin/plugin.json` has the new version and that `plugin/hooks/hooks.json` lists the same events and timeouts as `HooksInstaller.events` and `HooksInstaller.timeout(for:)`.
2. Check that `plugin/scripts/earshot-hook.sh` is executable in git:

   ```sh
   git ls-files -s plugin/scripts/earshot-hook.sh   # mode should be 100755
   ```

3. On a Mac with the released app installed and Earshot's hooks removed from `settings.json` (`earshot-hook --uninstall`), in a fresh Claude Code session:

   ```
   /plugin marketplace add knQzx/earshot
   /plugin install earshot@earshot
   ```

   Restart the session, confirm it shows up in the notch with live status and that an approval works, and that `earshot-hook --status` prints `viaPlugin`. Also try the one-step form, `/plugin install earshot --marketplace knQzx/earshot`, on a current Claude Code. Then remove it with `/plugin uninstall earshot@earshot`.

## 5. After the release

1. Add a new `## [Unreleased]` section at the top of `CHANGELOG.md`.
2. Make sure private vulnerability reporting is enabled in the repository settings (Security > Private vulnerability reporting), since SECURITY.md points there.
3. If anything about installing changed, update the README and the release notes text in `.github/workflows/release.yml`.
