const repository = "en-code23/reprise";
const releaseURL = `https://github.com/${repository}/releases/latest`;

async function wireLatestRelease() {
  try {
    const response = await fetch(
      `https://api.github.com/repos/${repository}/releases/latest`,
      {
        headers: { Accept: "application/vnd.github+json" },
      },
    );
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

document.querySelectorAll("[data-theme]").forEach((button) => {
  button.addEventListener("click", () => {
    const dark = button.dataset.theme === "dark";
    const path = dark ? "assets/library-dark.png" : "assets/library-light.png";
    document.getElementById("app-preview").src = path;
    document.getElementById("full-preview").href = path;
    document
      .querySelectorAll("[data-theme]")
      .forEach((item) =>
        item.setAttribute("aria-pressed", String(item === button)),
      );
  });
});

wireLatestRelease();
