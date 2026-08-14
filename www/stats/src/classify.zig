//! What a request *was*: which site, who asked, and what they asked for.
//!
//! Every judgement the numbers on stats.luciaos.com rest on is made in
//! this one file, so that a reader who wants to know what "a visitor"
//! means can find out by reading it rather than by trusting a chart.
//! Three of those judgements are worth stating out loud:
//!
//!  * **`curl` is not a robot.**  The install line on luce.luciaos.com
//!    is `curl … | bash`, so a curl fetching `install.sh` is the most
//!    interesting human on the site.  Tools get their own answer, and
//!    only crawlers and scanners are dropped from the visitor counts.
//!
//!  * **An asset is not a visit.**  A stylesheet fetched alongside a
//!    page would double the page's own number, so only pages count as
//!    views.  What is an asset is decided by extension, and the list
//!    is here rather than spread over the collector.
//!
//!  * **Fetching the script and running the install are two numbers.**
//!    `install.sh` is fetched by anyone who reads the install line;
//!    the archive is fetched only when the script actually proceeds.
//!    Reporting them as one number would flatter the download count,
//!    so they stay apart all the way to the dashboard.

const std = @import("std");

pub const Site = enum {
    luce,
    loom,
    luciaos,

    pub fn text(self: Site) []const u8 {
        return @tagName(self);
    }
};

/// Which of our sites a `Host:` names, or null for anything else —
/// a probe for someone else's domain that happened to reach the box.
pub fn site(host: []const u8) ?Site {
    // Caddy writes the authority; a non-default port would ride along.
    const name = if (std.mem.indexOfScalar(u8, host, ':')) |colon| host[0..colon] else host;
    if (eq(name, "luce.luciaos.com")) return .luce;
    if (eq(name, "loom.luciaos.com")) return .loom;
    if (eq(name, "luciaos.com") or eq(name, "www.luciaos.com")) return .luciaos;
    return null;
}

pub const Agent = enum {
    /// A person with a browser.
    browser,
    /// A person with a terminal: curl, wget, the installer itself.
    tool,
    /// A crawler, a scanner or a monitor.  Counted, never a visitor.
    robot,
};

/// Substrings that mean "not a person", matched case-insensitively.
/// `bot`, `crawler` and `spider` catch the overwhelming majority; the
/// rest are the ones seen in the wild that call themselves nothing.
const robots = [_][]const u8{
    "bot",                 "crawl",             "spider",             "slurp",
    "facebookexternalhit", "archiver",          "scrapy",             "zgrab",
    "masscan",             "nmap",              "censys",             "expanse",
    "internetmeasurement", "netcraft",          "netsystemsresearch", "paloaltonetworks",
    "leakix",              "scanner",           "probe",              "monitoring",
    "uptime",              "pingdom",           "statuscake",         "site24x7",
    "newrelic",            "datadog",           "headlesschrome",     "phantomjs",
    "puppeteer",           "playwright",        "selenium",           "python-requests",
    "python-urllib",       "go-http-client",    "java/",              "okhttp",
    "libwww-perl",         "apache-httpclient", "http_request",       "zabbix",
    "checkhost",           "feedfetcher",
};

/// Substrings that mean "a person at a terminal".
const tools = [_][]const u8{
    "curl/", "wget/", "libcurl", "httpie", "powershell", "aria2",
};

pub fn agent(text: []const u8) Agent {
    // Nothing at all is a scanner far more often than it is a person.
    if (std.mem.trim(u8, text, " \t").len == 0) return .robot;

    // Tools first: `curl` names itself plainly and matches nothing in
    // the robot list, but checking it first makes the rule readable —
    // an agent that says what it is gets taken at its word.
    for (tools) |needle| if (contains(text, needle)) return .tool;
    for (robots) |needle| if (contains(text, needle)) return .robot;
    return .browser;
}

pub const Resource = enum {
    /// Something a person reads.  The only thing counted as a view.
    page,
    /// Stylesheet, script, image, font — fetched *because* of a page.
    asset,
    /// `install/<version>/install.sh`: the install line being read.
    install_script,
    /// The toolchain archive: an install actually proceeding.
    archive,
    /// The editor extension.
    extension,
    /// Anything else: a probe, a `.php` fishing expedition, a favicon
    /// at a path we do not serve.
    other,
};

const asset_extensions = [_][]const u8{
    ".css",  ".js",  ".mjs",  ".map",  ".svg", ".png",  ".jpg",
    ".jpeg", ".gif", ".webp", ".avif", ".ico", ".woff", ".woff2",
    ".ttf",  ".otf", ".eot",  ".txt",  ".xml", ".json", ".webmanifest",
};

/// The path of a request, without its query.
pub fn path(uri: []const u8) []const u8 {
    const cut = std.mem.indexOfAny(u8, uri, "?#") orelse uri.len;
    return uri[0..cut];
}

pub fn resource(request_path: []const u8) Resource {
    if (std.mem.startsWith(u8, request_path, "/install/")) {
        if (std.mem.endsWith(u8, request_path, "install.sh")) return .install_script;
        if (endsWithAny(request_path, &.{ ".tar.gz", ".tgz", ".tar.xz", ".zip" })) return .archive;
    }
    if (std.mem.endsWith(u8, request_path, ".vsix")) return .extension;

    const last = lastSegment(request_path);
    if (std.mem.indexOfScalar(u8, last, '.') == null) return .page;
    if (endsWithAny(last, &.{ ".html", ".htm" })) return .page;
    if (endsWithAny(last, &asset_extensions)) return .asset;
    return .other;
}

/// The page a request should be filed under: `/guides/toolchain/` and
/// `/guides/toolchain/index.html` are one page, and the root is `/`.
pub fn page(request_path: []const u8) []const u8 {
    var trimmed = request_path;
    if (std.mem.endsWith(u8, trimmed, "index.html")) {
        trimmed = trimmed[0 .. trimmed.len - "index.html".len];
    }
    if (trimmed.len == 0) return "/";
    // One trailing slash, always, so `/guides` and `/guides/` agree.
    if (trimmed.len > 1 and !std.mem.endsWith(u8, trimmed, "/") and
        std.mem.indexOfScalar(u8, lastSegment(trimmed), '.') == null)
    {
        return trimmed;
    }
    return trimmed;
}

/// The host a `Referer` names, or "" when it names nothing usable.
/// Our own three sites answer "" too: a visitor arriving at a second
/// page of the same site did not come *from* anywhere.
pub fn referrer(url: []const u8) []const u8 {
    if (url.len == 0) return "";
    var rest = url;
    if (std.mem.indexOf(u8, rest, "://")) |mark| rest = rest[mark + 3 ..];
    // Strip any userinfo, then take up to the first /, ? or #.
    if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
        if (std.mem.indexOfAny(u8, rest[0..at], "/?#") == null) rest = rest[at + 1 ..];
    }
    const cut = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..cut];
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon];
    if (std.mem.startsWith(u8, host, "www.")) host = host["www.".len..];
    if (host.len == 0) return "";
    if (site(host) != null or eq(host, "luciaos.com")) return "";
    return host;
}

fn lastSegment(text: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, text, '/') orelse return text;
    return text[slash + 1 ..];
}

fn endsWithAny(text: []const u8, endings: []const []const u8) bool {
    for (endings) |ending| {
        if (text.len < ending.len) continue;
        if (eq(text[text.len - ending.len ..], ending)) return true;
    }
    return false;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

const testing = std.testing;

test "hosts land on the site they name" {
    try testing.expectEqual(Site.luce, site("luce.luciaos.com").?);
    try testing.expectEqual(Site.loom, site("loom.luciaos.com").?);
    try testing.expectEqual(Site.luciaos, site("luciaos.com").?);
    try testing.expectEqual(Site.luciaos, site("www.luciaos.com").?);
    try testing.expectEqual(Site.luce, site("LUCE.LUCIAOS.COM").?);
    try testing.expectEqual(Site.luce, site("luce.luciaos.com:443").?);
    try testing.expect(site("docs.luciaos.com") == null);
    try testing.expect(site("example.com") == null);
    try testing.expect(site("") == null);
}

test "curl is a person and a crawler is not" {
    try testing.expectEqual(Agent.tool, agent("curl/8.7.1"));
    try testing.expectEqual(Agent.tool, agent("Wget/1.21.4"));
    try testing.expectEqual(Agent.browser, agent(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36",
    ));
    try testing.expectEqual(Agent.browser, agent("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari/605.1.15"));
    try testing.expectEqual(Agent.robot, agent("Googlebot/2.1 (+http://www.google.com/bot.html)"));
    try testing.expectEqual(Agent.robot, agent("Mozilla/5.0 (compatible; bingbot/2.0)"));
    try testing.expectEqual(Agent.robot, agent("ClaudeBot/1.0"));
    try testing.expectEqual(Agent.robot, agent("Mozilla/5.0 (compatible; SemrushBot/7~bl)"));
    try testing.expectEqual(Agent.robot, agent("python-requests/2.31.0"));
    try testing.expectEqual(Agent.robot, agent("Go-http-client/1.1"));
    try testing.expectEqual(Agent.robot, agent(""));
    try testing.expectEqual(Agent.robot, agent("   "));
}

test "the install line and the install are different requests" {
    try testing.expectEqual(Resource.install_script, resource("/install/0.18/install.sh"));
    try testing.expectEqual(Resource.archive, resource("/install/0.18/luce-0.18-macos-aarch64.tar.gz"));
    try testing.expectEqual(Resource.extension, resource("/install/0.18/luce-language-0.4.0.vsix"));
}

test "pages count and assets do not" {
    try testing.expectEqual(Resource.page, resource("/"));
    try testing.expectEqual(Resource.page, resource("/guide/command-line/"));
    try testing.expectEqual(Resource.page, resource("/guide/reference/ownership/"));
    try testing.expectEqual(Resource.page, resource("/index.html"));
    try testing.expectEqual(Resource.asset, resource("/assets/style.css"));
    try testing.expectEqual(Resource.asset, resource("/assets/mark.svg"));
    try testing.expectEqual(Resource.asset, resource("/search-index.js"));
    try testing.expectEqual(Resource.asset, resource("/robots.txt"));
    try testing.expectEqual(Resource.other, resource("/wp-login.php"));
}

test "a query is not part of the path" {
    try testing.expectEqualStrings("/search", path("/search?q=ownership"));
    try testing.expectEqualStrings("/", path("/?utm_source=x"));
    try testing.expectEqualStrings("/a/b", path("/a/b#anchor"));
    try testing.expectEqualStrings("/a/b", path("/a/b"));
}

test "one page has one name" {
    try testing.expectEqualStrings("/", page("/"));
    try testing.expectEqualStrings("/", page("/index.html"));
    try testing.expectEqualStrings("/guides/", page("/guides/index.html"));
    try testing.expectEqualStrings("/guides/toolchain/", page("/guides/toolchain/"));
}

test "a referrer is a host, and our own sites are not referrers" {
    try testing.expectEqualStrings("news.ycombinator.com", referrer("https://news.ycombinator.com/item?id=1"));
    try testing.expectEqualStrings("google.com", referrer("https://www.google.com/"));
    try testing.expectEqualStrings("lobste.rs", referrer("https://lobste.rs"));
    try testing.expectEqualStrings("example.com", referrer("http://user@example.com/page"));
    try testing.expectEqualStrings("", referrer("https://luce.luciaos.com/guides/"));
    try testing.expectEqualStrings("", referrer("https://luciaos.com/"));
    try testing.expectEqualStrings("", referrer("https://www.luciaos.com/"));
    try testing.expectEqualStrings("", referrer(""));
}
