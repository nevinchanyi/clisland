class Clisland < Formula
  desc "Coding agent status in the MacBook notch for Claude Code, Codex and Gemini CLI"
  homepage "https://github.com/nevinchanyi/clisland"
  url "https://github.com/nevinchanyi/clisland/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "52215b22f1347893fc1b7f714b81c71dc0f135dcc346e193b598e3198a477771"
  license "MIT"
  head "https://github.com/nevinchanyi/clisland.git", branch: "main"

  depends_on macos: :sonoma

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin_path = Utils.safe_popen_read("swift", "build", "--disable-sandbox", "-c", "release", "--show-bin-path").chomp
    bin.install "#{bin_path}/clisland"
  end

  def caveats
    <<~EOS
      Connect your agent CLIs and start CLIsland at login:
        clisland setup
      Preview the UI:
        clisland demo
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/clisland version")
  end
end
