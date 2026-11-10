const repository = "en-code23/reprise";
const releaseURL = `https://github.com/${repository}/releases/latest`;
const systemPlatform = /win/i.test(navigator.userAgentData?.platform || navigator.platform || "") ? "windows" : "mac";

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
    const zip = release.assets?.find((asset) => asset.name.endsWith("-macOS.zip"));
    const windows = release.assets?.find((asset) => /-win-Setup\.exe$/i.test(asset.name));

    document.querySelectorAll("[data-download]").forEach((link) => {
      const platform = link.dataset.download === "auto" ? systemPlatform : link.dataset.download || "mac";
      const asset = platform === "windows" ? windows : dmg || zip;
      link.href = asset?.browser_download_url || release.html_url || releaseURL;
      const label = link.querySelector("[data-download-label]");
      if (label) label.textContent = platform === "windows" ? "Download for Windows" : "Download for Mac";
    });
    document.querySelectorAll("[data-version]").forEach((label) => {
      label.textContent = `${release.tag_name || "Latest"} · macOS & Windows`;
    });
  } catch {
    document.querySelectorAll("[data-download]").forEach((link) => {
      link.href = releaseURL;
    });
  }
}

let previewPlatform = systemPlatform;
let previewDark = false;
function renderPreview() {
  const windows = previewPlatform === "windows";
  const path = (windows ? "assets/windows-library.png" : previewDark ? "assets/library-dark.png" : "assets/library-light.png") + "?v=1.7.0";
  const preview = document.getElementById("app-preview");
  preview.src = path;
  preview.alt = windows ? "Native Reprise Windows project library with example sessions." : "Native Reprise Mac project library with example sessions.";
  preview.style.aspectRatio = windows ? "1044 / 788" : "1180 / 800";
  document.getElementById("full-preview").href = path;
  document.getElementById("preview-window-bar").hidden = windows;
  document.querySelector(".appearance").hidden = windows;
  document.querySelectorAll("[data-platform]").forEach(button => button.setAttribute("aria-pressed", String(button.dataset.platform === previewPlatform)));
}
document.querySelectorAll("[data-platform]").forEach(button => button.addEventListener("click", () => { previewPlatform = button.dataset.platform; renderPreview(); }));
document.querySelectorAll("[data-theme]").forEach((button) => {
  button.addEventListener("click", () => {
    previewDark = button.dataset.theme === "dark";
    renderPreview();
    document
      .querySelectorAll("[data-theme]")
      .forEach((item) =>
        item.setAttribute("aria-pressed", String(item === button)),
      );
  });
});

renderPreview();
wireLatestRelease();
