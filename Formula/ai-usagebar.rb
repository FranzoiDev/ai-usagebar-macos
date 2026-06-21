# Homebrew formula for AIUsageBar — builds the menu bar app from source.
#
# Building on the user's own machine means the binary is ad-hoc signed by their
# toolchain and never gets a quarantine flag, so Gatekeeper doesn't block it —
# no Developer ID, no notarization, no `xattr` dance.
#
# This file belongs in the tap repo FranzoiDev/homebrew-tap (path:
# Formula/ai-usagebar.rb), so users can `brew install franzoidev/tap/ai-usagebar`.
class AiUsagebar < Formula
  desc "Native macOS menu bar app that surfaces AI plan usage"
  homepage "https://github.com/FranzoiDev/ai-usagebar-macos"
  url "https://github.com/FranzoiDev/ai-usagebar-macos/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "036a8adc318e7ff0af848eace970db28cdafc9210a5efafbc7658ecc98167f6d"
  license "MIT"
  head "https://github.com/FranzoiDev/ai-usagebar-macos.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :ventura

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"

    app = prefix/"AIUsageBar.app"
    (app/"Contents/MacOS").mkpath
    (app/"Contents/Resources").mkpath
    cp ".build/release/AIUsageBar", app/"Contents/MacOS/AIUsageBar"
    cp "Resources/Info.plist", app/"Contents/Info.plist"

    # Re-sign ad-hoc so the bundled binary launches on Apple Silicon.
    system "codesign", "--force", "--sign", "-", app

    # Small launcher on PATH so `ai-usagebar` opens the menu bar app.
    (bin/"ai-usagebar").write <<~EOS
      #!/bin/bash
      exec open "#{opt_prefix}/AIUsageBar.app" "$@"
    EOS
  end

  def caveats
    <<~EOS
      AIUsageBar is a menu bar app (no Dock icon). Start it with:
        ai-usagebar

      For a reliable "Launch at Login", copy it into /Applications first:
        cp -R #{opt_prefix}/AIUsageBar.app /Applications/
      then enable it from the app's gear ▸ Settings.
    EOS
  end

  test do
    assert_path_exists prefix/"AIUsageBar.app/Contents/MacOS/AIUsageBar"
  end
end
