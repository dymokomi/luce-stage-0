#!/bin/sh
# Build lucelang.org into www/lucelang/out.
#
# The site is a hierarchy rather than a flat book. `pages` is the single table
# of URLs and parentage; each row has one HTML fragment under content/. This
# script gives every fragment the shared shell, builds section navigation and
# an on-page rail, substitutes version values from their authoritative Zig
# declarations, then checks links, anchors, duplicate ids, source paths, and
# orphaned fragments.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd "$here/../.." && pwd)
out="$here/out"

rm -rf "$out"
mkdir -p "$out/assets"

manifest=$(grep -v '^#' "$here/pages" | grep -v '^[[:space:]]*$')
mir_version=$(git -C "$repo" show HEAD:src/luce/mir/module.zig | sed -n 's/^pub const format_version: u32 = \([0-9][0-9]*\);/\1/p')
abi_version=$(git -C "$repo" show HEAD:src/luce/codegen/abi.zig | sed -n 's/^pub const version: u32 = \([0-9][0-9]*\);/\1/p')
release=$(git -C "$repo" show HEAD:VERSION | tr -d '[:space:]')

if [ -z "$mir_version" ] || [ -z "$abi_version" ] || [ -z "$release" ]; then
    echo "build: could not read the MIR, ABI, or release version" >&2
    exit 1
fi

echo "==> checked compiler traces"
if [ ! -f "$here/traces/build-info.txt" ]; then
    echo "build: checked trace artifacts are missing" >&2
    exit 1
fi
mkdir -p "$out/traces"
cp -R "$here/traces/." "$out/traces/"

field() {
    printf '%s\n' "$1" | cut -d'|' -f"$2"
}

html() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

html_attribute() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

depth_for() {
    if [ -z "$1" ]; then
        printf './'
    else
        printf '%s' "$1" | awk -F/ '{ for (i = 1; i <= NF; i++) printf "../" }'
    fi
}

tabs() {
    current=$1
    depth=$2
    printf '%s\n' "$manifest" | while IFS='|' read -r slug parent label title description; do
        if [ "$slug" = index ] || [ -n "$parent" ]; then continue; fi
        if [ "$slug" = "$current" ]; then class=' class="here"'; else class=; fi
        printf '<a%s href="%s%s/">%s</a>\n' "$class" "$depth" "$slug" "$(html "$label")"
    done
}

sidebar() {
    current=$1
    section=$2
    depth=$3
    title=$(printf '%s\n' "$manifest" | awk -F'|' -v wanted="$section" '$1 == wanted { print $4; exit }')
    printf '<aside class="side"><details class="nav" open><summary>%s</summary><ul>\n' "$(html "$title")"
    printf '%s\n' "$manifest" | while IFS='|' read -r slug parent label page_title description; do
        if [ "$slug" != "$section" ] && [ "$parent" != "$section" ]; then continue; fi
        if [ "$slug" = "$current" ]; then class=' class="here"'; else class=; fi
        if [ "$slug" = "$section" ]; then nav_label=Overview; else nav_label=$label; fi
        printf '<li><a%s href="%s%s/" data-description="%s">%s</a></li>\n' \
            "$class" "$depth" "$slug" "$(html_attribute "$description")" "$(html "$nav_label")"
    done
    printf '</ul></details></aside>\n'
}

heading_links() {
    source=$1
    place=$2
    count=$(grep -Ec '^<h[23] id="[^"]+">' "$source" || true)
    if [ "$count" -lt 2 ]; then
        printf '<aside class="%s"></aside>\n' "$place"
        return
    fi
    if [ "$place" = side ]; then
        printf '<aside class="side"><details class="nav" open><summary>On this page</summary><ul>\n'
    else
        printf '<aside class="rail"><nav aria-label="On this page"><h2>On this page</h2><ul>\n'
    fi
    grep -E '^<h[23] id="[^"]+">' "$source" | while IFS= read -r heading; do
        level=$(printf '%s\n' "$heading" | sed -n 's/^<h\([23]\) .*/\1/p')
        anchor=$(printf '%s\n' "$heading" | sed -n 's/^<h[23] id="\([^"]*\)">.*/\1/p')
        words=$(printf '%s\n' "$heading" | sed 's/<[^>]*>//g')
        printf '<li class="h%s"><a href="#%s">%s</a></li>\n' "$level" "$anchor" "$words"
    done
    if [ "$place" = side ]; then printf '</ul></details></aside>\n'; else printf '</ul></nav></aside>\n'; fi
}

breadcrumbs() {
    slug=$1
    parent=$2
    depth=$3
    title=$4
    if [ "$slug" = index ]; then return; fi
    printf '<nav class="crumbs" aria-label="Breadcrumb"><a href="%s">Map</a><span>/</span>' "$depth"
    if [ -n "$parent" ]; then
        parent_title=$(printf '%s\n' "$manifest" | awk -F'|' -v wanted="$parent" '$1 == wanted { print $3; exit }')
        printf '<a href="%s%s/">%s</a><span>/</span>' "$depth" "$parent" "$(html "$parent_title")"
    fi
    printf '<span aria-current="page">%s</span></nav>\n' "$(html "$title")"
}

sequence() {
    current=$1
    section=$2
    depth=$3
    rows=$(printf '%s\n' "$manifest" | awk -F'|' -v wanted="$section" '$1 == wanted || $2 == wanted')
    previous=$(printf '%s\n' "$rows" | awk -F'|' -v wanted="$current" '$1 == wanted { print before; exit } { before = $0 }')
    next=$(printf '%s\n' "$rows" | awk -F'|' -v wanted="$current" 'found { print; exit } $1 == wanted { found = 1 }')
    if [ -z "$previous" ] && [ -z "$next" ]; then return; fi
    printf '<nav class="seq" aria-label="Previous and next pages">\n'
    if [ -n "$previous" ]; then
        previous_slug=$(field "$previous" 1)
        previous_title=$(field "$previous" 4)
        printf '<a class="back" href="%s%s/"><span>Previous</span>%s</a>\n' "$depth" "$previous_slug" "$(html "$previous_title")"
    else
        printf '<span></span>\n'
    fi
    if [ -n "$next" ]; then
        next_slug=$(field "$next" 1)
        next_title=$(field "$next" 4)
        printf '<a class="on" href="%s%s/"><span>Next</span>%s</a>\n' "$depth" "$next_slug" "$(html "$next_title")"
    fi
    printf '</nav>\n'
}

escape_html() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$1"
}

trace_guide() {
    guide_stage=$1
    guide_file=$2
    case "$guide_stage" in
        mir)
            guide_title='MIR instruction guide'
            guide_primer='<code>r7</code> is one typed intermediate value, <code>%2</code> is a local storage slot, and <code>b1</code> is a basic block. Read each block from top to bottom, then follow its final control-flow instruction.'
            ;;
        llvm)
            guide_title='LLVM IR instruction guide'
            guide_primer='<code>%7</code> is an SSA value, <code>i64</code> is a 64-bit integer type, <code>ptr</code> is a pointer, and <code>@name</code> is a module symbol. Numbered labels divide the function into basic blocks.'
            ;;
        asm)
            guide_title='ARM64 instruction guide'
            guide_primer='<code>x8</code> is a 64-bit register; <code>w8</code> is its low 32 bits. A leading <code>#</code> marks a constant, brackets describe a memory address, and conditional instructions read the processor flags set by the preceding arithmetic or comparison.'
            ;;
        *) return ;;
    esac

    printf '<details class="trace-guide"><summary>%s <span>hover, focus, or tap dotted terms</span></summary>\n' "$guide_title"
    printf '<p class="trace-primer">%s</p>\n' "$guide_primer"
    printf '<p class="trace-guide-scope">Hover or focus a dotted term in the file for its explanation. On a touch screen, tap a term to keep the note open and tap elsewhere to close it. The list includes the operations that appear in this file.</p>\n<dl>\n'
    while IFS='|' read -r note_stage pattern term explanation; do
        case "$note_stage" in ''|'#'*) continue ;; esac
        if [ "$note_stage" = "$guide_stage" ] && grep -Eq "$pattern" "$guide_file"; then
            help_token=$term
            case "$guide_stage:$term" in
                'mir:class NAME') help_token=class ;;
                'mir:struct NAME') help_token=struct ;;
                'mir:interface NAME') help_token=interface ;;
                'mir:union NAME') help_token=union ;;
                'mir:func …') help_token=func ;;
                'mir:local %N') help_token=local ;;
                'mir:b0, b1, …'|'mir:r0, r1, …') help_token= ;;
                'mir:intrinsic NAME') help_token=intrinsic ;;
                'mir:intrinsic '*) help_token=${term#intrinsic } ;;
                'mir:call NAME') help_token=call ;;
                'mir:branch '*) help_token=branch ;;
                'llvm:@name = …'|'llvm:numeric label'|'llvm:%0, %1, …') help_token= ;;
                'llvm:define … @name') help_token=define ;;
                'llvm:declare … @name') help_token=declare ;;
            esac
            if [ -n "$help_token" ]; then
                help_attribute=" data-help-token=\"$(html_attribute "$help_token")\""
            else
                help_attribute=
            fi
            printf '<div%s><dt><code>%s</code></dt><dd>%s</dd></div>\n' "$help_attribute" "$(html "$term")" "$explanation"
        fi
    done < "$here/trace-notes"
    printf '</dl></details>\n'
}

trace_panel() {
    name=$1
    depth=$2
    source="$out/traces/$name.luc"
    mir="$out/traces/$name.mir"
    llvm="$out/traces/$name.ll"
    assembly="$out/traces/$name.asm"
    for trace_file in "$source" "$mir" "$llvm" "$assembly"; do
        if [ ! -f "$trace_file" ]; then
            echo "build: trace $trace_file is missing" >&2
            exit 1
        fi
    done

    cat <<TRACE_HEAD
<div class="trace" data-stepper>
  <div class="trace-head">
    <div><span class="eyebrow">Compiler trace</span><strong>Follow one program through four representations</strong></div>
    <a href="${depth}traces/build-info.txt">compiler build information</a>
  </div>
  <div class="trace-tabs" role="group" aria-label="Choose a compiler representation">
    <button type="button" data-step-select="source">1 · Luce</button>
    <button type="button" data-step-select="mir">2 · MIR</button>
    <button type="button" data-step-select="llvm">3 · LLVM IR</button>
    <button type="button" data-step-select="assembly">4 · ARM64</button>
  </div>
  <section class="trace-panel" data-step-panel="source">
    <div class="trace-caption"><p><b>Luce source.</b> Names and indentation describe the program for a reader.</p><a href="${depth}traces/$name.luc">open source file</a></div>
    <div class="code trace-code"><pre><code>
TRACE_HEAD
    escape_html "$source"
    cat <<TRACE_MIR
</code></pre></div>
  </section>
  <section class="trace-panel" data-step-panel="mir">
    <div class="trace-caption"><p><b>Luce MIR.</b> Types, registers, blocks, calls, and lifetime operations form the instruction plan sent to the LLVM backend.</p><a href="${depth}traces/$name.mir">open MIR file</a></div>
TRACE_MIR
    trace_guide mir "$mir"
    cat <<TRACE_MIR_CODE
    <div class="code trace-code"><pre><code data-trace-language="mir">
TRACE_MIR_CODE
    escape_html "$mir"
    cat <<TRACE_LL
</code></pre></div>
  </section>
  <section class="trace-panel" data-step-panel="llvm">
    <div class="trace-caption"><p><b>LLVM IR.</b> The backend expands MIR into typed memory operations, calls, checks, and control-flow blocks for LLVM.</p><a href="${depth}traces/$name.ll">open LLVM IR file</a></div>
TRACE_LL
    trace_guide llvm "$llvm"
    cat <<TRACE_LL_CODE
    <div class="code trace-code"><pre><code data-trace-language="llvm">
TRACE_LL_CODE
    escape_html "$llvm"
    cat <<TRACE_ASM
</code></pre></div>
  </section>
  <section class="trace-panel" data-step-panel="assembly">
    <div class="trace-caption"><p><b>ARM64 object code.</b> LLVM selected these instructions, registers, calls, and branch conditions for this target.</p><a href="${depth}traces/$name.asm">open assembly file</a></div>
TRACE_ASM
    trace_guide asm "$assembly"
    cat <<TRACE_ASM_CODE
    <div class="code trace-code"><pre><code data-trace-language="asm">
TRACE_ASM_CODE
    escape_html "$assembly"
    cat <<TRACE_FOOT
</code></pre></div>
  </section>
</div>
TRACE_FOOT
}

render_content() {
    source=$1
    depth=$2
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            '<!-- trace:'*' -->')
                name=${line#'<!-- trace:'}
                name=${name%' -->'}
                trace_panel "$name" "$depth"
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$source" | sed \
        -e "s|@/|$depth|g" \
        -e 's|@repo/|https://github.com/dymokomi/luciaos/blob/main/|g' \
        -e "s|@mir_version@|$mir_version|g" \
        -e "s|@abi_version@|$abi_version|g" \
        -e "s|@release@|$release|g"
}

printf '%s\n' "$manifest" | while IFS='|' read -r slug parent label title description; do
    render_label=$label
    render_title=$title
    render_description=$description
    html_render_label=$(html "$render_label")
    html_render_title=$(html "$render_title")
    html_render_description=$(html_attribute "$render_description")
    if [ "$slug" = index ]; then
        page="$out/index.html"
        source="$here/content/index.html"
        depth=./
        section=
        canonical=https://lucelang.org/
    else
        page="$out/$slug/index.html"
        source="$here/content/$slug.html"
        mkdir -p "$(dirname "$page")"
        depth=$(depth_for "$slug")
        section=${slug%%/*}
        canonical="https://lucelang.org/$slug/"
    fi
    if [ ! -f "$source" ]; then
        echo "build: $source is missing" >&2
        exit 1
    fi

    {
        cat <<HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(if [ "$slug" = index ]; then printf '%s' "$html_render_title"; else printf '%s · Luce engineering' "$html_render_title"; fi)</title>
<meta name="description" content="$html_render_description">
<link rel="canonical" href="$canonical">
<meta property="og:title" content="$html_render_title">
<meta property="og:description" content="$html_render_description">
<meta property="og:type" content="website">
<meta property="og:url" content="$canonical">
<link rel="stylesheet" href="${depth}assets/core.css">
<link rel="stylesheet" href="${depth}assets/style.css">
<link rel="icon" href="${depth}assets/mark.svg" type="image/svg+xml">
<script>try{var t=localStorage.getItem("luce-theme");if(t)document.documentElement.dataset.theme=t}catch(e){}</script>
</head>
<body data-root="$depth">
<a class="skip" href="#content">Skip to content</a>
<header class="top">
<a class="mark" href="$depth">Luce / engineering</a>
<nav class="tabs" aria-label="Systems">
$(tabs "$section" "$depth")
</nav>
<div class="tools">
<label class="find"><span class="sr">Search the atlas</span><input id="q" type="search" placeholder="Find a system" autocomplete="off" aria-controls="hits"></label>
<a class="cross" href="https://luce.luciaos.com">Learn Luce</a>
<a class="cross" href="https://luciaos.com">LuciaOS</a>
<button id="theme" type="button" aria-label="Switch between light and dark">◑</button>
</div>
<div id="hits" hidden></div>
</header>
<div class="shell">
HEAD
        if [ -z "$section" ]; then heading_links "$source" side; else sidebar "$slug" "$section" "$depth"; fi
        printf '<main id="content">\n'
        breadcrumbs "$slug" "$parent" "$depth" "$render_label"
        printf '<article>\n<h1>%s</h1>\n' "$html_render_title"
        render_content "$source" "$depth"
        printf '</article>\n'
        if [ -n "$section" ]; then sequence "$slug" "$section" "$depth"; fi
        printf '</main>\n'
        if [ -n "$section" ]; then heading_links "$source" rail; else printf '<aside class="rail"></aside>\n'; fi
        cat <<FOOT
</div>
<footer>
<p>This atlas explains the implementation built from the LuciaOS repository today. For the language guide and checked examples, use <a href="https://luce.luciaos.com">luce.luciaos.com</a>. MIR format <strong>$mir_version</strong> · host ABI <strong>$abi_version</strong> · release <strong>$release</strong>.</p>
</footer>
<script src="${depth}assets/search-index.js" defer></script>
<script src="${depth}assets/site.js" defer></script>
</body>
</html>
FOOT
    } > "$page"
    echo "    $page"
done

cp "$here/../shared/core.css" "$out/assets/core.css"
cp "$here/assets/style.css" "$here/assets/site.js" "$here/assets/mark.svg" "$out/assets/"
cmp "$here/../shared/core.css" "$out/assets/core.css"

{
    printf 'window.LUCELANG_SEARCH = [\n'
    printf '%s\n' "$manifest" | while IFS='|' read -r slug parent label title description; do
        escaped_title=$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')
        escaped_description=$(printf '%s' "$description" | sed 's/\\/\\\\/g; s/"/\\"/g')
        if [ "$slug" = index ]; then url=/; else url="/$slug/"; fi
        printf '  {u:"%s",t:"%s",d:"%s"},\n' "$url" "$escaped_title" "$escaped_description"
    done
    printf '];\n'
} > "$out/assets/search-index.js"

{
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
    printf '%s\n' "$manifest" | while IFS='|' read -r slug parent label title description; do
        if [ "$slug" = index ]; then url=https://lucelang.org/; else url="https://lucelang.org/$slug/"; fi
        printf '  <url><loc>%s</loc></url>\n' "$url"
    done
    printf '</urlset>\n'
} > "$out/sitemap.xml"
printf 'User-agent: *\nAllow: /\nSitemap: https://lucelang.org/sitemap.xml\n' > "$out/robots.txt"

echo "==> implementation links"
for source_path in $(grep -Rho 'data-source="[^"]*"' "$here/content" | sed 's/^data-source="//; s/"$//' | sort -u); do
    if [ ! -e "$repo/$source_path" ]; then
        echo "  broken source: $source_path" >&2
        exit 1
    fi
done

echo "==> content roster"
for source in $(find "$here/content" -name '*.html' -type f | sort); do
    relative=${source#"$here/content/"}
    slug=${relative%.html}
    if ! printf '%s\n' "$manifest" | awk -F'|' -v wanted="$slug" '$1 == wanted { found = 1 } END { exit !found }'; then
        echo "  orphaned content: $source" >&2
        exit 1
    fi
done

echo "==> links and anchors"
broken=0
for page in $(find "$out" -name '*.html' -type f); do
    duplicates=$(grep -o ' id="[^"]*"' "$page" | sort | uniq -d || true)
    if [ -n "$duplicates" ]; then
        echo "  duplicate id: $page: $duplicates" >&2
        broken=$((broken + 1))
    fi
    for href in $(grep -o 'href="[^"]*"' "$page" | sed 's/^href="//; s/"$//'); do
        case $href in
            http://*|https://*|mailto:*|data:*|'#') continue ;;
        esac
        directory=$(dirname "$page")
        anchor=
        case $href in
            \#*) target=$page; anchor=${href#\#} ;;
            *\#*) target=$directory/${href%%\#*}; anchor=${href#*\#} ;;
            *) target=$directory/$href ;;
        esac
        case $target in */) target=${target}index.html ;; esac
        if [ ! -f "$target" ]; then
            echo "  broken: $page -> $href (no $target)" >&2
            broken=$((broken + 1))
            continue
        fi
        if [ -n "$anchor" ] && ! grep -q "id=\"$anchor\"" "$target"; then
            echo "  broken: $page -> $href (no #$anchor)" >&2
            broken=$((broken + 1))
        fi
    done
    if grep -Eq '@/|@repo/|@mir_version@|@abi_version@|@release@' "$page"; then
        echo "  unexpanded placeholder: $page" >&2
        broken=$((broken + 1))
    fi
done
if [ "$broken" -ne 0 ]; then
    echo "build: $broken integrity error(s)" >&2
    exit 1
fi

count=$(printf '%s\n' "$manifest" | wc -l | tr -d ' ')
echo "==> done: $out ($count pages, MIR $mir_version, ABI $abi_version)"
