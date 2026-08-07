/* Two small things, and nothing else: a theme toggle and a copy
 * button on every code panel.
 *
 * The site is entirely readable with this file blocked.  Nothing here
 * loads anything, stores anything but the chosen theme, or talks to
 * any other host.  The key is the one luciaos.com and
 * luce.luciaos.com already use, so a person who chose dark on one of
 * them meets dark on this one. */
(function () {
  "use strict";

  var root = document.documentElement;
  var button = document.getElementById("theme");
  if (button) {
    button.addEventListener("click", function () {
      var dark = root.dataset.theme
        ? root.dataset.theme === "dark"
        : window.matchMedia("(prefers-color-scheme: dark)").matches;
      var next = dark ? "light" : "dark";
      root.dataset.theme = next;
      try { localStorage.setItem("luce-theme", next); } catch (e) {}
    });
  }

  document.querySelectorAll(".code").forEach(function (panel) {
    var body = panel.querySelector("code, samp");
    if (!body || !navigator.clipboard) return;
    var copy = document.createElement("button");
    copy.type = "button";
    copy.className = "copy";
    copy.textContent = "copy";
    copy.addEventListener("click", function () {
      navigator.clipboard.writeText(body.innerText).then(function () {
        copy.textContent = "copied";
        setTimeout(function () { copy.textContent = "copy"; }, 1200);
      });
    });
    panel.appendChild(copy);
  });
})();
