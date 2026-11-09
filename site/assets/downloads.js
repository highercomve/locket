// The download cards: the latest release's files, per platform. The site
// build writes the latest release to release.json, so visitors don't hit
// GitHub's API rate limit; the live API is only a fallback.
(function () {
  var endpoint = "https://api.github.com/repos/highercomve/locket/releases/latest";
  var releases = "https://github.com/highercomve/locket/releases/latest";
  var section = document.getElementById("download");
  if (!section) return;
  var cached = section.dataset.releaseJson;
  var version = section.querySelector("[data-release-version]");
  var primary = document.querySelector("[data-primary-download]");
  var cards = Array.prototype.slice.call(section.querySelectorAll("[data-download-os]"));
  var ua = navigator.userAgent;
  var here = /Android/i.test(ua) ? null : /Win/i.test(ua) ? "windows" : /Mac/i.test(ua) && !/iPhone|iPad/i.test(ua) ? "macos" : /Linux|X11/i.test(ua) ? "linux" : null;
  var NAMES = { linux: "Linux", windows: "Windows", macos: "macOS" };

  // What a release file is: the app (by package) or the command line (by CPU).
  // The update payloads (locket-app-*-windows.exe, *.app.tar.gz) and the
  // manifests aren't listed: the installers carry the same builds.
  function describe(name) {
    var m;
    if (/-x86_64\.flatpak$/.test(name)) return { os: "linux", kind: "app", format: "flatpak", label: "Flatpak" };
    if (/-x86_64\.AppImage$/.test(name)) return { os: "linux", kind: "app", format: "appimage", label: "AppImage" };
    if (/_amd64\.deb$/.test(name)) return { os: "linux", kind: "app", format: "deb", label: ".deb" };
    if (/\.x86_64\.rpm$/.test(name)) return { os: "linux", kind: "app", format: "rpm", label: ".rpm" };
    // arm64 Linux: listed under the x86_64 picker, as links.
    if (/-aarch64\.flatpak$/.test(name)) return { os: "linux", kind: "arm", format: "flatpak", label: "Flatpak" };
    if (/-aarch64\.AppImage$/.test(name)) return { os: "linux", kind: "arm", format: "appimage", label: "AppImage" };
    if (/_arm64\.deb$/.test(name)) return { os: "linux", kind: "arm", format: "deb", label: ".deb" };
    if (/\.aarch64\.rpm$/.test(name)) return { os: "linux", kind: "arm", format: "rpm", label: ".rpm" };
    if (/^Locket-[\d.]+-setup\.exe$/.test(name)) return { os: "windows", kind: "app", label: "Installer (.exe)" };
    if (/^Locket-[\d.]+-macos-arm64\.dmg$/.test(name)) return { os: "macos", kind: "app", label: "Disk image (.dmg)" };
    if ((m = /^locket-[\d.]+-(x86_64|aarch64)-linux$/.exec(name))) return { os: "linux", kind: "cli", label: m[1] };
    if (/^locket-[\d.]+-x86_64-windows\.exe$/.test(name)) return { os: "windows", kind: "cli", label: "x86_64" };
    if (/^locket-[\d.]+-aarch64-macos$/.test(name)) return { os: "macos", kind: "cli", label: "Apple silicon" };
    if (/^locket-[\d.]+-x86_64-macos$/.test(name)) return { os: "macos", kind: "cli", label: "Intel" };
    return null;
  }

  function size(bytes) {
    return bytes >= 1e9 ? (bytes / 1e9).toFixed(1) + " GB" : Math.max(1, Math.round(bytes / 1e6)) + " MB";
  }

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text) node.textContent = text;
    return node;
  }

  function button(file, text, ghost) {
    var a = el("a", "btn download-btn " + (ghost ? "btn-ghost" : "btn-primary"));
    a.append(el("span", null, text), el("small", "download-size"));
    a.set = function (next) {
      a.href = next.url;
      a.querySelector("small").textContent = size(next.bytes);
      a.setAttribute("aria-label", text + ": " + next.label + ", " + size(next.bytes));
    };
    a.set(file);
    return a;
  }

  // Linux: one button, a choice of package.
  function linuxApp(list, apps) {
    var picker = el("div", "asset-options");
    picker.setAttribute("role", "radiogroup");
    picker.setAttribute("aria-label", "Package");
    var link = button(apps[0], "Download");
    apps.forEach(function (file, i) {
      var label = el("label");
      var input = el("input");
      input.type = "radio";
      input.name = "linux-package";
      input.value = file.format;
      input.checked = i === 0;
      input.addEventListener("change", function () { link.set(file); });
      label.append(input, el("span", null, file.label));
      picker.append(label);
    });
    list.append(picker, link);
  }

  function cliRow(list, clis, title) {
    var row = el("p", "asset-cli");
    row.append(el("span", null, (title || "Command line") + ": "));
    clis.forEach(function (file, i) {
      if (i) row.append(document.createTextNode(" · "));
      var a = el("a", null, file.label);
      a.href = file.url;
      a.title = size(file.bytes);
      row.append(a);
    });
    list.append(row);
  }

  function retry(message) {
    version.textContent = message;
    cards.forEach(function (card) {
      var list = card.querySelector("[data-assets]");
      list.replaceChildren();
      var again = el("button", "btn btn-ghost download-btn", "Try again");
      again.type = "button";
      again.addEventListener("click", load);
      var page = el("a", "asset-cli", "or open the release page");
      page.href = releases;
      list.append(again, page);
    });
  }

  function fetchJson(url, headers) {
    return fetch(url, { cache: "no-cache", headers: headers || {} }).then(function (r) {
      if (!r.ok) throw new Error(url + ": " + r.status);
      return r.json();
    });
  }

  function load() {
    version.textContent = "Finding the latest release…";
    var first = cached ? fetchJson(cached).catch(function () { return null; }) : Promise.resolve(null);
    first.then(function (release) {
      if (release && release.assets && release.assets.length) return release;
      return fetchJson(endpoint, { Accept: "application/vnd.github+json" });
    }).then(function (release) {
      var files = { linux: { app: [], arm: [], cli: [] }, windows: { app: [], arm: [], cli: [] }, macos: { app: [], arm: [], cli: [] } };
      (release.assets || []).forEach(function (asset) {
        var type = describe(asset.name);
        // Only files of this project's releases.
        if (!type || asset.browser_download_url.indexOf("https://github.com/highercomve/locket/releases/download/") !== 0) return;
        type.url = asset.browser_download_url;
        type.bytes = asset.size;
        files[type.os][type.kind].push(type);
      });
      var order = { flatpak: 0, appimage: 1, deb: 2, rpm: 3 };
      files.linux.app.sort(function (a, b) { return order[a.format] - order[b.format]; });
      files.linux.arm.sort(function (a, b) { return order[a.format] - order[b.format]; });
      files.linux.cli.sort(function (a, b) { return a.label.localeCompare(b.label) * -1; });
      version.textContent = release.tag_name ? "Latest release · " + release.tag_name : "Latest release";
      cards.forEach(function (card) {
        var os = card.dataset.downloadOs;
        var list = card.querySelector("[data-assets]");
        list.replaceChildren();
        var mine = files[os];
        if (!mine.app.length && !mine.arm.length && !mine.cli.length) {
          list.append(el("span", "asset-loading", "Not in the latest release."));
          return;
        }
        if (os === "linux" && mine.app.length) linuxApp(list, mine.app);
        else if (mine.app.length) list.append(button(mine.app[0], "Download"));
        if (mine.arm.length) cliRow(list, mine.arm, "arm64 app");
        if (mine.cli.length) cliRow(list, mine.cli);
      });
      var preferred = here && files[here].app[0];
      if (primary && preferred) {
        primary.href = preferred.url;
        primary.textContent = "Download for " + NAMES[here];
        primary.title = preferred.label + " · " + size(preferred.bytes);
      }
    }).catch(function (error) {
      console.warn("Could not load the Locket release:", error);
      retry("The downloads couldn't be listed just now.");
    });
  }

  load();
})();
