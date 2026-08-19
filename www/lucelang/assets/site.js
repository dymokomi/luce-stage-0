/* The atlas is complete without JavaScript. This file adds theme memory,
 * responsive navigation, copying, reading position, title search, and the
 * small step/filter controls inside explanatory diagrams. It loads nothing
 * and sends nothing. */
(function () {
  "use strict";

  document.documentElement.classList.add("js");

  // Theme
  var root = document.documentElement;
  var theme = document.getElementById("theme");
  if (theme) {
    theme.addEventListener("click", function () {
      var dark = root.dataset.theme
        ? root.dataset.theme === "dark"
        : window.matchMedia("(prefers-color-scheme: dark)").matches;
      var next = dark ? "light" : "dark";
      root.dataset.theme = next;
      try { localStorage.setItem("luce-theme", next); } catch (error) {}
    });
  }

  // The section list collapses before the article on a narrow screen.
  var narrow = window.matchMedia("(max-width: 56rem)");
  var navigation = document.querySelector(".side details.nav");
  function fitNavigation() {
    if (!navigation) return;
    navigation.open = !narrow.matches;
  }
  fitNavigation();
  if (narrow.addEventListener) narrow.addEventListener("change", fitNavigation);

  // Copy code panels.
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

  // Mark the nearest heading in the right rail.
  var rail = document.querySelector(".rail nav");
  if (rail && "IntersectionObserver" in window) {
    var marks = {};
    rail.querySelectorAll("a").forEach(function (link) {
      marks[decodeURIComponent(link.hash.slice(1))] = link;
    });
    var visible = [];
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var at = visible.indexOf(entry.target.id);
        if (entry.isIntersecting && at < 0) visible.push(entry.target.id);
        if (!entry.isIntersecting && at >= 0) visible.splice(at, 1);
      });
      Object.keys(marks).forEach(function (id) { marks[id].classList.remove("on"); });
      if (visible.length && marks[visible[0]]) marks[visible[0]].classList.add("on");
    }, { rootMargin: "-64px 0px -70% 0px" });
    Object.keys(marks).forEach(function (id) {
      var target = document.getElementById(id);
      if (target) observer.observe(target);
    });
  }

  // Search page titles and descriptions from the build-generated index.
  var query = document.getElementById("q");
  var hits = document.getElementById("hits");
  var depth = document.body.dataset.root || "./";
  function showSearch(needle) {
    var rows = (window.LUCELANG_SEARCH || []).map(function (row) {
      var title = row.t.toLowerCase();
      var description = row.d.toLowerCase();
      var rank = title === needle ? 120 : title.indexOf(needle) >= 0 ? 90 : description.indexOf(needle) >= 0 ? 40 : 0;
      return { row: row, rank: rank };
    }).filter(function (found) { return found.rank > 0; })
      .sort(function (a, b) { return b.rank - a.rank; }).slice(0, 12);

    hits.textContent = "";
    if (!rows.length) {
      var empty = document.createElement("div");
      empty.className = "none";
      empty.textContent = "Nothing matches “" + needle + "”.";
      hits.appendChild(empty);
    } else {
      rows.forEach(function (found) {
        var link = document.createElement("a");
        link.href = depth + found.row.u.slice(1);
        var title = document.createElement("b");
        title.textContent = found.row.t;
        var description = document.createElement("em");
        description.textContent = found.row.d;
        link.appendChild(title);
        link.appendChild(description);
        hits.appendChild(link);
      });
    }
    hits.hidden = false;
  }
  if (query && hits) {
    query.addEventListener("input", function () {
      var needle = query.value.trim().toLowerCase();
      if (needle.length < 2) { hits.hidden = true; return; }
      showSearch(needle);
    });
    query.addEventListener("keydown", function (event) {
      if (event.key === "Escape") { hits.hidden = true; query.blur(); }
      if (event.key === "Enter") {
        var first = hits.querySelector("a");
        if (first) location.href = first.href;
      }
    });
    document.addEventListener("click", function (event) {
      if (!hits.contains(event.target) && event.target !== query) hits.hidden = true;
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "/" && document.activeElement !== query) {
        event.preventDefault();
        query.focus();
      }
    });
  }

  // Compiler terms: mark every explained operation. The first occurrence of
  // each term joins the keyboard tab order; later occurrences remain available
  // to mouse and touch readers without turning a long trace into hundreds of
  // repeated tab stops.
  var tracePopover = document.createElement("div");
  tracePopover.id = "trace-popover";
  tracePopover.className = "trace-popover";
  tracePopover.setAttribute("role", "tooltip");
  tracePopover.hidden = true;
  var tracePopoverTerm = document.createElement("code");
  var tracePopoverText = document.createElement("p");
  tracePopover.appendChild(tracePopoverTerm);
  tracePopover.appendChild(tracePopoverText);
  document.body.appendChild(tracePopover);

  function escapePattern(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  document.querySelectorAll("code[data-trace-language]").forEach(function (code) {
    var panel = code.closest(".trace-panel");
    if (!panel) return;
    var help = {};
    panel.querySelectorAll(".trace-guide [data-help-token]").forEach(function (item) {
      var token = item.dataset.helpToken;
      var description = item.querySelector("dd");
      if (token && description) help[token] = description.textContent.trim();
    });
    var tokens = Object.keys(help).sort(function (a, b) { return b.length - a.length; });
    if (!tokens.length) return;

    var source = code.textContent;
    var matcher = new RegExp("(^|[^A-Za-z0-9_@.])(" + tokens.map(escapePattern).join("|") + ")(?=$|[^A-Za-z0-9_.])", "gm");
    var found = [];
    var used = {};
    var match;
    while ((match = matcher.exec(source))) {
      var token = match[2];
      var first = !used[token];
      used[token] = true;
      found.push({ start: match.index + match[1].length, token: token, tabbable: first });
    }
    if (!found.length) return;

    var fragment = document.createDocumentFragment();
    var cursor = 0;
    found.forEach(function (item) {
      fragment.appendChild(document.createTextNode(source.slice(cursor, item.start)));
      var term = document.createElement("button");
      term.type = "button";
      term.className = "trace-term";
      term.dataset.help = help[item.token];
      term.textContent = item.token;
      if (!item.tabbable) term.tabIndex = -1;
      term.setAttribute("aria-label", item.token + ": " + help[item.token]);
      fragment.appendChild(term);
      cursor = item.start + item.token.length;
    });
    fragment.appendChild(document.createTextNode(source.slice(cursor)));
    code.replaceChildren(fragment);
  });

  var activeTraceTerm = null;
  var tracePopoverPinned = false;
  function placeTracePopover(term) {
    var box = term.getBoundingClientRect();
    var margin = 10;
    var left = Math.min(window.innerWidth - tracePopover.offsetWidth - margin, Math.max(margin, box.left));
    var top = box.bottom + 8;
    if (top + tracePopover.offsetHeight > window.innerHeight - margin) {
      top = Math.max(margin, box.top - tracePopover.offsetHeight - 8);
    }
    tracePopover.style.left = left + "px";
    tracePopover.style.top = top + "px";
  }
  function showTracePopover(term, pinned) {
    if (activeTraceTerm && activeTraceTerm !== term) activeTraceTerm.removeAttribute("aria-describedby");
    activeTraceTerm = term;
    tracePopoverPinned = pinned;
    tracePopoverTerm.textContent = term.textContent;
    tracePopoverText.textContent = term.dataset.help;
    tracePopover.hidden = false;
    term.setAttribute("aria-describedby", tracePopover.id);
    placeTracePopover(term);
  }
  function hideTracePopover() {
    if (activeTraceTerm) activeTraceTerm.removeAttribute("aria-describedby");
    activeTraceTerm = null;
    tracePopoverPinned = false;
    tracePopover.hidden = true;
  }

  document.addEventListener("pointerover", function (event) {
    if (event.pointerType !== "mouse") return;
    var term = event.target.closest && event.target.closest(".trace-term");
    if (term && !tracePopoverPinned) showTracePopover(term, false);
  });
  document.addEventListener("pointerout", function (event) {
    if (event.pointerType !== "mouse" || tracePopoverPinned) return;
    var term = event.target.closest && event.target.closest(".trace-term");
    if (term && !term.contains(event.relatedTarget)) hideTracePopover();
  });
  document.addEventListener("focusin", function (event) {
    if (event.target.classList && event.target.classList.contains("trace-term")) showTracePopover(event.target, false);
  });
  document.addEventListener("focusout", function (event) {
    if (!tracePopoverPinned && event.target === activeTraceTerm) hideTracePopover();
  });
  document.addEventListener("click", function (event) {
    var term = event.target.closest && event.target.closest(".trace-term");
    if (term) {
      if (activeTraceTerm === term && tracePopoverPinned) hideTracePopover();
      else showTracePopover(term, true);
      return;
    }
    if (!tracePopover.contains(event.target)) hideTracePopover();
  });
  document.addEventListener("keydown", function (event) {
    if (event.key === "Escape" && activeTraceTerm) hideTracePopover();
  });
  window.addEventListener("resize", function () {
    if (activeTraceTerm) placeTracePopover(activeTraceTerm);
  });
  window.addEventListener("scroll", hideTracePopover, true);

  // A diagram stepper owns buttons and panels with matching data-step values.
  document.querySelectorAll("[data-stepper]").forEach(function (stepper) {
    var buttons = stepper.querySelectorAll("[data-step-select]");
    var panels = stepper.querySelectorAll("[data-step-panel]");
    var compilerTrace = stepper.classList.contains("trace");
    function select(name) {
      buttons.forEach(function (button) {
        button.setAttribute("aria-pressed", button.dataset.stepSelect === name ? "true" : "false");
      });
      panels.forEach(function (panel) { panel.hidden = panel.dataset.stepPanel !== name; });
      if (compilerTrace) {
        try { sessionStorage.setItem("lucelang-trace-stage", name); } catch (error) {}
      }
    }
    buttons.forEach(function (button, index) {
      button.addEventListener("click", function () { select(button.dataset.stepSelect); });
      button.addEventListener("keydown", function (event) {
        if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
        event.preventDefault();
        var offset = event.key === "ArrowRight" ? 1 : -1;
        var next = (index + offset + buttons.length) % buttons.length;
        buttons[next].focus();
        select(buttons[next].dataset.stepSelect);
      });
    });
    if (buttons.length) {
      var initial = buttons[0].dataset.stepSelect;
      if (compilerTrace) {
        try {
          var remembered = sessionStorage.getItem("lucelang-trace-stage");
          if (remembered && stepper.querySelector('[data-step-select="' + remembered + '"]')) initial = remembered;
        } catch (error) {}
      }
      select(initial);
    }
  });

  // Ownership maps can isolate Zig, Luce, or machine layers.
  document.querySelectorAll("[data-owner-map]").forEach(function (map) {
    var buttons = map.querySelectorAll("[data-owner-select]");
    var nodes = map.querySelectorAll("[data-owner]");
    function select(owner) {
      buttons.forEach(function (button) {
        button.setAttribute("aria-pressed", button.dataset.ownerSelect === owner ? "true" : "false");
      });
      nodes.forEach(function (node) {
        node.classList.toggle("dim", owner !== "all" && node.dataset.owner !== owner);
      });
    }
    buttons.forEach(function (button) {
      button.addEventListener("click", function () { select(button.dataset.ownerSelect); });
    });
    select("all");
  });
})();
