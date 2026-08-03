/* Three small things, and nothing else: a theme toggle, a copy button
 * on every sample, an "on this page" marker that follows the reading
 * position, and search over the index the generator emitted.
 *
 * The site is entirely readable with this file blocked.  Nothing here
 * loads anything, stores anything but the chosen theme, or talks to
 * any other host. */
(function () {
  "use strict";

  // ---- theme ---------------------------------------------------------
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

  // ---- copy ----------------------------------------------------------
  document.querySelectorAll("button.copy").forEach(function (copy) {
    copy.addEventListener("click", function () {
      var code = copy.parentNode.querySelector("code, samp");
      if (!code || !navigator.clipboard) return;
      navigator.clipboard.writeText(code.innerText).then(function () {
        copy.textContent = "copied";
        setTimeout(function () { copy.textContent = "copy"; }, 1200);
      });
    });
  });

  // ---- on this page --------------------------------------------------
  var rail = document.querySelector(".rail nav");
  if (rail && "IntersectionObserver" in window) {
    var marks = {};
    rail.querySelectorAll("a").forEach(function (link) {
      marks[decodeURIComponent(link.hash.slice(1))] = link;
    });
    var seen = [];
    var watcher = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          var id = entry.target.id;
          var at = seen.indexOf(id);
          if (entry.isIntersecting && at < 0) seen.push(id);
          if (!entry.isIntersecting && at >= 0) seen.splice(at, 1);
        });
        for (var id in marks) marks[id].classList.remove("on");
        if (seen.length) {
          var first = null;
          Object.keys(marks).forEach(function (id) {
            if (first === null && seen.indexOf(id) >= 0) first = id;
          });
          if (first) marks[first].classList.add("on");
        }
      },
      { rootMargin: "-64px 0px -70% 0px" }
    );
    Object.keys(marks).forEach(function (id) {
      var target = document.getElementById(id);
      if (target) watcher.observe(target);
    });
  }

  // ---- search --------------------------------------------------------
  var box = document.getElementById("q");
  var hits = document.getElementById("hits");
  if (!box || !hits) return;

  var here = location.pathname;
  var depth = here.replace(/\/[^/]*$/, "/").split("/").length - 2;
  var up = depth > 0 ? new Array(depth + 1).join("../") : "./";

  function score(row, needle) {
    var best = 0;
    if (row.t.toLowerCase().indexOf(needle) >= 0) best = 100;
    else if (row.b.toLowerCase().indexOf(needle) >= 0) best = 40;
    var anchor = "";
    row.h.forEach(function (heading) {
      if (best < 70 && heading[0].toLowerCase().indexOf(needle) >= 0) {
        best = 70;
        anchor = "#" + heading[1];
      }
    });
    return { rank: best, anchor: anchor };
  }

  function show(needle) {
    var rows = window.LUCE_SEARCH || [];
    var found = [];
    rows.forEach(function (row) {
      var got = score(row, needle);
      if (got.rank > 0) found.push({ row: row, rank: got.rank, anchor: got.anchor });
    });
    found.sort(function (a, b) { return b.rank - a.rank; });
    found = found.slice(0, 12);

    hits.textContent = "";
    if (!found.length) {
      var empty = document.createElement("div");
      empty.className = "none";
      empty.textContent = "Nothing matches “" + needle + "”.";
      hits.appendChild(empty);
      hits.hidden = false;
      return;
    }
    found.forEach(function (found_row) {
      var link = document.createElement("a");
      link.href = up + found_row.row.u.slice(1) + found_row.anchor;
      var title = document.createElement("b");
      title.textContent = found_row.row.s + " › " + found_row.row.t;
      var blurb = document.createElement("em");
      blurb.textContent = found_row.row.b;
      link.appendChild(title);
      link.appendChild(blurb);
      hits.appendChild(link);
    });
    hits.hidden = false;
  }

  box.addEventListener("input", function () {
    var needle = box.value.trim().toLowerCase();
    if (needle.length < 2) { hits.hidden = true; return; }
    show(needle);
  });
  box.addEventListener("keydown", function (event) {
    if (event.key === "Escape") { hits.hidden = true; box.blur(); }
    if (event.key === "Enter") {
      var first = hits.querySelector("a");
      if (first) location.href = first.href;
    }
  });
  document.addEventListener("click", function (event) {
    if (!hits.contains(event.target) && event.target !== box) hits.hidden = true;
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "/" && document.activeElement !== box) {
      event.preventDefault();
      box.focus();
    }
  });
})();
