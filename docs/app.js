const repository = "en-code23/reprise";
const releaseURL = `https://github.com/${repository}/releases/latest`;

async function wireLatestRelease() {
  try {
    const response = await fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!response.ok) throw new Error("No release yet");
    const release = await response.json();
    const dmg = release.assets?.find((asset) => asset.name.endsWith(".dmg"));
    const zip = release.assets?.find((asset) => asset.name.endsWith(".zip"));
    const asset = dmg || zip;

    document.querySelectorAll("[data-download]").forEach((link) => {
      link.href = asset?.browser_download_url || release.html_url || releaseURL;
    });
    document.querySelectorAll("[data-version]").forEach((label) => {
      label.textContent = `${release.tag_name || "Latest"} · macOS 14+`;
    });
  } catch {
    document.querySelectorAll("[data-download]").forEach((link) => {
      link.href = releaseURL;
    });
  }
}

document.querySelector("[data-copy-demo]")?.addEventListener("click", async (event) => {
  const button = event.currentTarget;
  try {
    await navigator.clipboard.writeText('codex --resume "019cba47-918e"');
    button.textContent = "✓";
    window.setTimeout(() => { button.textContent = "⧉"; }, 1400);
  } catch {
    button.textContent = "✓";
  }
});

wireLatestRelease();
