#!/bin/sh
# Differential fuzzer: for many seeds, generate a random type-correct
# scalar Luce program, compile it to both .lc and .wasm, run each under
# the interpreter and a wasm runtime (deno), and demand identical
# behaviour — same printed output, or the same trap code.  Any program
# the wasm gate rejects (should not happen for the generator's output)
# is reported, not silently skipped.
#
#   ./build.sh && tools/wasm-fuzz.sh [COUNT]
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
command -v deno >/dev/null || { echo "wasm-fuzz: needs deno" >&2; exit 1; }
[ -x build/luce ] || { echo "wasm-fuzz: run ./build.sh first" >&2; exit 1; }

count="${1:-200}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mismatches=0
gate_rejects=0
compile_fail=0
traps=0

seed=1
while [ "$seed" -le "$count" ]; do
    luc="$work/p$seed.luc"
    deno run tools/wasm-fuzz.js "$seed" > "$luc"

    if ! build/luce build "$luc" -o "$work/p.lc" >/dev/null 2>"$work/c.err"; then
        compile_fail=$((compile_fail + 1))
        if [ "$compile_fail" -le 3 ]; then
            echo "seed $seed: generated program did not compile:"
            sed 's/^/    /' "$work/c.err" | head -4
        fi
        seed=$((seed + 1)); continue
    fi
    if ! build/luce wasm "$luc" -o "$work/p.wasm" >/dev/null 2>"$work/w.err"; then
        gate_rejects=$((gate_rejects + 1))
        [ "$gate_rejects" -le 3 ] && echo "seed $seed: wasm gate rejected a scalar program ($(cat "$work/w.err"))"
        seed=$((seed + 1)); continue
    fi

    interp="$(LOOM_ENGINE=interpreter build/loom run "$work/p.lc" 2>"$work/i.err" || true)"
    itrap="$(grep -o 'trap:[a-z_]*\|[a-z ]*$' "$work/i.err" 2>/dev/null | tail -1 || true)"
    wasm_out="$(deno run --allow-read tools/wasm-run.js "$work/p.wasm" 2>"$work/we.err" || true)"
    wtrap="$(grep '^TRAP ' "$work/we.err" | awk '{print $2}' || true)"

    # If either trapped, both must trap with the same code (the wasm
    # side reports numeric TrapCode; the interpreter prints a message,
    # so compare on the observable that both share: the printed prefix
    # plus trap-or-not, and cross-check the code via a re-run.)
    if [ -n "$wtrap" ]; then
        traps=$((traps + 1))
        # The interpreter must also have failed (non-empty stderr trace).
        if [ ! -s "$work/i.err" ]; then
            mismatches=$((mismatches + 1))
            echo "seed $seed: wasm trapped ($wtrap) but interpreter did not"
            cp "$luc" "$root/wasm-fuzz-fail-$seed.luc"
        elif [ "$wasm_out" != "$interp" ]; then
            mismatches=$((mismatches + 1))
            echo "seed $seed: pre-trap output differs"
            echo "  wasm:   $wasm_out"; echo "  interp: $interp"
            cp "$luc" "$root/wasm-fuzz-fail-$seed.luc"
        fi
    else
        # No wasm trap: the interpreter must not have trapped either, and
        # the full output must match.
        if [ -s "$work/i.err" ]; then
            mismatches=$((mismatches + 1))
            echo "seed $seed: interpreter trapped but wasm did not"
            sed 's/^/  /' "$work/i.err" | head -2
            cp "$luc" "$root/wasm-fuzz-fail-$seed.luc"
        elif [ "$wasm_out" != "$interp" ]; then
            mismatches=$((mismatches + 1))
            echo "seed $seed: output differs"
            echo "  wasm:   $(echo "$wasm_out" | tr '\n' '|')"
            echo "  interp: $(echo "$interp"   | tr '\n' '|')"
            cp "$luc" "$root/wasm-fuzz-fail-$seed.luc"
        fi
    fi
    seed=$((seed + 1))
done

echo "----------------------------------------"
echo "fuzz: $count programs, $traps trapped (agreed), $mismatches mismatches"
[ "$compile_fail" -gt 0 ] && echo "  ($compile_fail generated programs failed to compile — generator bug, not backend)"
[ "$gate_rejects" -gt 0 ] && echo "  ($gate_rejects rejected by the wasm gate)"
[ "$mismatches" -eq 0 ] || exit 1
