/* The page's one script: read data/stats.json, draw it, and nothing else.
 *
 * It loads no library, fetches nothing but its own data file, and
 * stores nothing but the theme the family's other two sites already
 * store.  Charts are drawn as SVG at the container's real pixel size
 * rather than scaled from a fixed viewBox, so a 2px line is 2px and
 * a 12px label is 12px on every screen — the whole reason there is a
 * resize observer in here.
 *
 * The arithmetic is deliberately thin.  Sums, a maximum and a scale
 * are all this file computes; everything else was counted on the
 * server and is drawn as given, so a number that looks wrong is wrong
 * in the collector rather than somewhere in here.
 */
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
      redraw();
    });
  }

  var SVG = "http://www.w3.org/2000/svg";
  var data = null;
  var window_days = 90;
  var charts = [];

  // ------------------------------------------------------------ helpers

  function make(tag, attributes, text) {
    var node = document.createElementNS(SVG, tag);
    for (var name in attributes) {
      if (attributes[name] !== null && attributes[name] !== undefined) {
        node.setAttribute(name, attributes[name]);
      }
    }
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function count(value) {
    return value.toLocaleString("en-US");
  }

  /* Bytes in the unit a person would say them in. */
  function size(bytes) {
    var units = ["B", "kB", "MB", "GB", "TB"];
    var at = 0;
    var value = bytes;
    while (value >= 1000 && at < units.length - 1) { value /= 1000; at++; }
    return (value < 10 && at > 0 ? value.toFixed(1) : Math.round(value)) + " " + units[at];
  }

  function sum(values) {
    return values.reduce(function (total, value) { return total + value; }, 0);
  }

  /* The last `window_days` of a series, and of the day labels. */
  function recent(values) {
    return values.slice(Math.max(0, values.length - window_days));
  }

  function ink(name) {
    return getComputedStyle(document.body).getPropertyValue("--" + name).trim();
  }

  /* A day as "13 Aug", which is what an axis has room for. */
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  function shortDay(text) {
    var parts = text.split("-");
    return Number(parts[2]) + " " + months[Number(parts[1]) - 1];
  }

  function longDay(text) {
    var parts = text.split("-");
    return Number(parts[2]) + " " + months[Number(parts[1]) - 1] + " " + parts[0];
  }

  /* Axis ticks a person would choose: 0, something round, the top. */
  function ceiling(highest) {
    if (highest <= 4) return 4;
    var power = Math.pow(10, Math.floor(Math.log10(highest)));
    var steps = [1, 2, 2.5, 5, 10];
    for (var at = 0; at < steps.length; at++) {
      var candidate = steps[at] * power;
      if (candidate >= highest) return candidate;
    }
    return 10 * power;
  }

  // -------------------------------------------------------- the tiles

  function sparkline(values, color) {
    var width = 120, height = 26;
    var svg = make("svg", { width: width, height: height,
                            viewBox: "0 0 " + width + " " + height,
                            role: "presentation" });
    var top = ceiling(Math.max.apply(null, values.concat([1])));
    var step = values.length > 1 ? width / (values.length - 1) : width;
    var points = values.map(function (value, at) {
      return [at * step, height - 2 - (value / top) * (height - 4)];
    });

    var line = points.map(function (point, at) {
      return (at ? "L" : "M") + point[0].toFixed(1) + " " + point[1].toFixed(1);
    }).join(" ");

    svg.appendChild(make("path", {
      d: line + " L" + width + " " + height + " L0 " + height + " Z",
      fill: color, class: "wash"
    }));
    svg.appendChild(make("path", { d: line, stroke: color, class: "series" }));
    return svg;
  }

  function tile(label, value, under, values, color) {
    var box = document.createElement("div");
    box.className = "tile";

    var name = document.createElement("span");
    name.className = "label";
    name.textContent = label;
    box.appendChild(name);

    var number = document.createElement("span");
    number.className = "value";
    number.textContent = value;
    box.appendChild(number);

    if (under) {
      var note = document.createElement("span");
      note.className = "under";
      note.textContent = under;
      box.appendChild(note);
    }
    if (values) box.appendChild(sparkline(values, ink(color)));
    return box;
  }

  function drawTiles() {
    var host = document.getElementById("tiles");
    host.textContent = "";

    // People, not the sum of the three sites: one person who reads two
    // of them is one person.  The collector counts that separately and
    // the report carries it as its own series.
    var visitors = recent(data.people), views = totals("views");
    var hits = totals("hits"), robots = totals("robots"), bytes = totals("bytes");
    var script = recent(data.installs.script);
    var runs = recent(data.installs.runs);
    var over = "in the last " + window_days + " days";

    host.appendChild(tile("People", count(sum(visitors)), over, visitors, "accent"));
    host.appendChild(tile("Pages read", count(sum(views)), over, views, "accent"));
    host.appendChild(tile("Installs", count(sum(runs)),
      sum(script) ? count(sum(script)) + " read the install line" : over, runs, "accent"));
    host.appendChild(tile("Served", size(sum(bytes)),
      count(sum(hits)) + " requests, " + count(sum(robots)) + " of them machines",
      hits, "quiet"));
  }

  // -------------------------------------------------------- the charts

  /* One time chart.  `series` is [{label, color, values}] — two or
   * three of them, which is where a categorical palette is honest. */
  function timeChart(plot, legend, table, series, unit) {
    var chart = {
      plot: plot, legend: legend, table: table, series: series, unit: unit
    };
    charts.push(chart);
    renderChart(chart);
  }

  function renderChart(chart) {
    var plot = chart.plot;
    var days = recent(data.days);
    var series = chart.series.map(function (one) {
      return { label: one.label, color: ink(one.color), values: recent(one.values) };
    });

    plot.textContent = "";

    if (chart.legend) {
      chart.legend.textContent = "";
      // Identity never rests on colour alone: every series is named.
      series.forEach(function (one, at) {
        var key = document.createElement("span");
        key.className = "key-" + chart.series[at].color;
        var swatch = document.createElement("i");
        var name = document.createElement("b");
        name.textContent = one.label;
        key.appendChild(swatch);
        key.appendChild(name);
        chart.legend.appendChild(key);
      });
    }

    var width = Math.max(320, plot.clientWidth || 640);
    var height = plot.classList.contains("tall") ? 300 : 220;
    var pad = { top: 12, right: 16, bottom: 26, left: 44 };
    var inner = { w: width - pad.left - pad.right, h: height - pad.top - pad.bottom };

    var highest = 0;
    series.forEach(function (one) {
      one.values.forEach(function (value) { if (value > highest) highest = value; });
    });
    var top = ceiling(highest);

    var svg = make("svg", {
      width: width, height: height, viewBox: "0 0 " + width + " " + height,
      role: "img", "aria-label": chart.series.map(function (one) {
        return one.label;
      }).join(", ") + " a day"
    });

    function x(at) {
      return pad.left + (days.length > 1 ? (at / (days.length - 1)) * inner.w : inner.w / 2);
    }
    function y(value) {
      return pad.top + inner.h - (value / top) * inner.h;
    }

    // Gridlines and their values, one step off the surface.
    [0, 0.5, 1].forEach(function (fraction) {
      var value = top * fraction;
      var at = y(value);
      svg.appendChild(make("line", {
        x1: pad.left, x2: width - pad.right, y1: at, y2: at, class: "grid"
      }));
      svg.appendChild(make("text", {
        x: pad.left - 8, y: at + 4, "text-anchor": "end",
        class: "axis axis-value"
      }, count(Math.round(value))));
    });

    // About five dates, always including the last day.
    var every = Math.max(1, Math.round(days.length / 5));
    days.forEach(function (day, at) {
      if (at % every !== 0 && at !== days.length - 1) return;
      if (at !== days.length - 1 && days.length - 1 - at < every * 0.6) return;
      svg.appendChild(make("text", {
        x: x(at), y: height - 8,
        "text-anchor": at === 0 ? "start" : (at === days.length - 1 ? "end" : "middle"),
        class: "axis"
      }, shortDay(day)));
    });

    series.forEach(function (one) {
      var line = one.values.map(function (value, at) {
        return (at ? "L" : "M") + x(at).toFixed(1) + " " + y(value).toFixed(1);
      }).join(" ");

      // A single series gets its wash; several would muddy each other.
      if (series.length === 1) {
        svg.appendChild(make("path", {
          d: line + " L" + x(one.values.length - 1) + " " + y(0) + " L" + x(0) + " " + y(0) + " Z",
          fill: one.color, class: "wash"
        }));
      }
      svg.appendChild(make("path", { d: line, stroke: one.color, class: "series" }));
    });

    // The hover layer: a crosshair, a dot per series, and a tooltip.
    var rule = make("line", { class: "crosshair", y1: pad.top, y2: pad.top + inner.h, opacity: 0 });
    svg.appendChild(rule);
    var dots = series.map(function (one) {
      var dot = make("circle", { r: 4, fill: one.color, class: "dot", opacity: 0 });
      svg.appendChild(dot);
      return dot;
    });

    plot.appendChild(svg);

    var tip = document.createElement("div");
    tip.className = "tip";
    tip.hidden = true;
    plot.appendChild(tip);

    function show(event) {
      var box = svg.getBoundingClientRect();
      var offset = event.clientX - box.left;
      var at = Math.round(((offset - pad.left) / inner.w) * (days.length - 1));
      if (at < 0) at = 0;
      if (at > days.length - 1) at = days.length - 1;

      rule.setAttribute("x1", x(at));
      rule.setAttribute("x2", x(at));
      rule.setAttribute("opacity", 1);

      var rows = "<span class='when'>" + longDay(days[at]) + "</span>";
      series.forEach(function (one, index) {
        dots[index].setAttribute("cx", x(at));
        dots[index].setAttribute("cy", y(one.values[at]));
        dots[index].setAttribute("opacity", 1);
        // The dot carries the hue; the label stays ink, because a
        // light series colour is unreadable as text.
        rows += "<div class='row'><span><i style='background:" + one.color +
          "'></i>" + one.label + "</span><b>" +
          count(one.values[at]) + "</b></div>";
      });
      tip.innerHTML = rows;
      tip.hidden = false;
      // Follows the pointer, but never off the top of its own box.
      tip.style.left = Math.min(Math.max(x(at), 80), width - 80) + "px";
      tip.style.top = Math.max(tip.offsetHeight + 14,
        event.clientY - box.top) + "px";
    }

    function hide() {
      rule.setAttribute("opacity", 0);
      dots.forEach(function (dot) { dot.setAttribute("opacity", 0); });
      tip.hidden = true;
    }

    svg.addEventListener("pointermove", show);
    svg.addEventListener("pointerleave", hide);

    if (chart.table) drawTable(chart.table, days, series);
  }

  /* Nothing on this page is gated behind being able to see a chart. */
  function drawTable(host, days, series) {
    var head = "<tr><th>Day</th>" + series.map(function (one) {
      return "<th>" + one.label + "</th>";
    }).join("") + "</tr>";

    var body = "";
    for (var at = days.length - 1; at >= 0; at--) {
      var blank = series.every(function (one) { return one.values[at] === 0; });
      if (blank) continue;
      body += "<tr><td>" + longDay(days[at]) + "</td>" + series.map(function (one) {
        return "<td>" + count(one.values[at]) + "</td>";
      }).join("") + "</tr>";
    }
    if (!body) body = "<tr><td colspan='" + (series.length + 1) + "'>Nothing yet.</td></tr>";

    host.innerHTML = "<div class='scroll'><table><thead>" + head +
      "</thead><tbody>" + body + "</tbody></table></div>";
  }

  // --------------------------------------------------------- the lists

  var regions = null;
  try {
    regions = new Intl.DisplayNames(["en"], { type: "region" });
  } catch (e) { regions = null; }

  function country(code) {
    if (!regions) return code;
    try { return regions.of(code) || code; } catch (e) { return code; }
  }

  var origins = {
    luce: "https://luce.luciaos.com",
    loom: "https://loom.luciaos.com",
    luciaos: "https://luciaos.com"
  };

  function drawList(host, rows, describe) {
    host.textContent = "";
    if (!rows.length) {
      var empty = document.createElement("p");
      empty.className = "empty";
      empty.textContent = "Nothing yet.";
      host.appendChild(empty);
      return;
    }

    var most = rows[0].count || 1;
    var list = document.createElement("div");
    list.className = "rows";

    rows.forEach(function (entry) {
      var row = document.createElement("div");
      row.className = "row";
      row.style.setProperty("--share", (entry.count / most) * 100 + "%");

      var what = document.createElement("div");
      what.className = "what";
      describe(what, entry);
      row.appendChild(what);

      var number = document.createElement("div");
      number.className = "count";
      number.textContent = count(entry.count);
      row.appendChild(number);

      list.appendChild(row);
    });
    host.appendChild(list);
  }

  function drawLists() {
    drawList(document.getElementById("top-pages"),
      data.top.pages.slice().sort(function (a, b) { return b.count - a.count; }).slice(0, 14),
      function (into, entry) {
        var tag = document.createElement("em");
        tag.textContent = entry.site;
        into.appendChild(tag);
        var link = document.createElement("a");
        link.href = origins[entry.site] + entry.key;
        link.textContent = entry.key;
        into.appendChild(link);
      });

    drawList(document.getElementById("top-referrers"), data.top.referrers,
      function (into, entry) {
        var link = document.createElement("a");
        link.href = "https://" + entry.key;
        link.rel = "noreferrer";
        link.textContent = entry.key;
        into.appendChild(link);
      });

    drawList(document.getElementById("top-countries"), data.top.countries,
      function (into, entry) {
        into.textContent = country(entry.key);
      });
  }

  // ---------------------------------------------------------- the page

  function site(name) {
    return data.sites.filter(function (one) { return one.name === name; })[0];
  }

  /* One measure summed across the three sites, over the chosen window. */
  function totals(field) {
    var out = [];
    data.sites.forEach(function (one) {
      recent(one[field]).forEach(function (value, at) { out[at] = (out[at] || 0) + value; });
    });
    return out;
  }

  /* The same sum, unwindowed: a chart takes whole series and slices
   * them itself, so windowing here would slice them twice. */
  function whole(field) {
    var out = [];
    data.sites.forEach(function (one) {
      one[field].forEach(function (value, at) { out[at] = (out[at] || 0) + value; });
    });
    return out;
  }

  function redraw() {
    if (!data) return;
    drawTiles();
    charts = [];

    timeChart(
      document.getElementById("visitors-plot"),
      document.getElementById("visitors-legend"),
      document.getElementById("visitors-table"),
      [
        { label: "luce.luciaos.com", color: "luce", values: site("luce").visitors },
        { label: "loom.luciaos.com", color: "loom", values: site("loom").visitors },
        { label: "luciaos.com", color: "luciaos", values: site("luciaos").visitors }
      ]);

    timeChart(
      document.getElementById("installs-plot"),
      document.getElementById("installs-legend"),
      document.getElementById("installs-table"),
      [
        { label: "Read the install line", color: "quiet", values: data.installs.script },
        { label: "Installed the toolchain", color: "luce", values: data.installs.runs }
      ]);

    var machines = whole("robots");
    var people = whole("hits").map(function (value, at) {
      return value - (machines[at] || 0);
    });

    timeChart(
      document.getElementById("traffic-plot"),
      document.getElementById("traffic-legend"),
      null,
      [
        { label: "People", color: "accent", values: people },
        { label: "Crawlers and scanners", color: "quiet", values: machines }
      ]);

    drawLists();
  }

  function ready() {
    var since = document.getElementById("since");
    since.textContent = data.since
      ? "Counting since " + longDay(data.since) + ". Days are UTC."
      : "Counting from today. There is nothing here yet — come back tomorrow.";

    var stamp = new Date(data.generated * 1000);
    document.getElementById("generated").textContent =
      "Last collected " + stamp.toISOString().replace("T", " ").slice(0, 16) + " UTC.";

    document.querySelectorAll(".range").forEach(function (control) {
      control.addEventListener("click", function () {
        document.querySelectorAll(".range").forEach(function (other) {
          other.classList.toggle("on", other === control);
        });
        window_days = Number(control.dataset.days);
        redraw();
      });
      control.classList.toggle("on", Number(control.dataset.days) === window_days);
    });

    redraw();
  }

  /* The narrowest offered range that still covers everything counted.
   * On the first day a 90-day window is 89 days of flat zero and one
   * spike, which reads as a broken chart rather than a new one; as the
   * history grows this widens on its own and then stops mattering. */
  function fits(loaded) {
    var offered = Array.prototype.map.call(
      document.querySelectorAll(".range"),
      function (control) { return Number(control.dataset.days); }
    ).sort(function (a, b) { return a - b; });

    var span = offered[offered.length - 1];
    if (loaded.since) {
      var first = loaded.days.indexOf(loaded.since);
      if (first >= 0) span = loaded.days.length - first;
    }
    for (var at = 0; at < offered.length; at++) {
      if (offered[at] >= span) return offered[at];
    }
    return offered[offered.length - 1];
  }

  var pending = null;
  window.addEventListener("resize", function () {
    if (pending) clearTimeout(pending);
    pending = setTimeout(function () {
      charts.forEach(renderChart);
    }, 120);
  });

  fetch("data/stats.json", { cache: "no-cache" })
    .then(function (answer) {
      if (!answer.ok) throw new Error(answer.status);
      return answer.json();
    })
    .then(function (loaded) {
      data = loaded;
      window_days = fits(loaded);
      ready();
    })
    .catch(function () {
      document.getElementById("since").textContent =
        "The numbers could not be loaded just now.";
    });
})();
