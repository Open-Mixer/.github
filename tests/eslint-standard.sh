#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas
# The shared ESLint config (.github/eslint/openmixer.config.mjs) and the ratchet a repository builds on it: ESLint's own
# bulk suppressions. Installs the pinned versions (.github/eslint/package.json) into a scratch project, then proves:
#   - an exported function without JSDoc, a missing @param, a missing @returns and a missing @throws are each red;
#   - a type-checked rule (no-floating-promises) is red in a .ts file;
#   - --suppress-all makes the tree green, a NEW finding is red, a FIXED one left in the file is red until pruned.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
cache=${OMX_ESLINT_STANDARD_CACHE:-}

mkdir -p "$tmp/p/src"; cd "$tmp/p"
node -e '
  const d = require(process.argv[1]).devDependencies;
  require("fs").writeFileSync("package.json", JSON.stringify({ name: "scratch", private: true, type: "module", devDependencies: d }));
' "$here/.github/eslint/package.json"
if [ -n "$cache" ] && [ -d "$cache/node_modules" ]; then cp -r "$cache/node_modules" .; else
  npm install --no-audit --no-fund --silent >/dev/null
fi
[ -f "$here/.github/eslint/openmixer.config.mjs" ] || fail "no .github/eslint/openmixer.config.mjs"

cat > eslint.config.mjs <<EOC
import { pathToFileURL } from 'node:url';
const { default: shared } = await import(pathToFileURL(\`\${process.env.OPENMIXER_DOTGITHUB}/.github/eslint/openmixer.config.mjs\`).href);
export default [{ ignores: ['node_modules/**'] }, ...shared];
EOC
cat > tsconfig.json <<'EOC'
{ "compilerOptions": { "target": "ES2022", "module": "NodeNext", "moduleResolution": "NodeNext", "strict": true, "noEmit": true, "skipLibCheck": true }, "include": ["src/**/*.ts"] }
EOC
export OPENMIXER_DOTGITHUB=$here
lint() { npx eslint "$@" >out.txt 2>&1; }
good() { lint "$@" || { cat out.txt; fail "expected green: $*"; }; }
red() { # rule, args
  local rule=$1; shift
  if lint "$@"; then fail "expected red ($rule) but eslint passed"; fi
  grep -q "$rule" out.txt || { cat out.txt; fail "red, but not for $rule"; }
}

cat > src/ok.mjs <<'EOC'
/**
 * Adds two numbers.
 * @param {number} a first
 * @param {number} b second
 * @returns {number} the sum
 */
export function add(a, b) { return a + b; }
EOC
cat > src/ok.ts <<'EOC'
/**
 * Says hello.
 * @param name who
 * @returns the greeting
 */
export function hello(name: string): string { return `hello ${name}`; }
EOC
good .

cat > src/nodoc.mjs <<'EOC'
export function nodoc() { return 1; }
EOC
red jsdoc/require-jsdoc .
rm src/nodoc.mjs
cat > src/internal.mjs <<'EOC'
function internalOnly(a) { return a; }
internalOnly(1);
EOC
good .   # require-jsdoc is for EXPORTED functions only
rm src/internal.mjs

cat > src/noparam.mjs <<'EOC'
/**
 * Doc.
 * @returns {number} one
 */
export function f(a) { return a; }
EOC
red jsdoc/require-param .; rm src/noparam.mjs
cat > src/noreturns.mjs <<'EOC'
/**
 * Doc.
 * @param {number} a one
 */
export function f(a) { return a; }
EOC
red jsdoc/require-returns .; rm src/noreturns.mjs
cat > src/nothrows.mjs <<'EOC'
/**
 * Doc.
 * @param {number} a one
 * @returns {number} one
 */
export function f(a) { if (a < 0) { throw new Error('neg'); } return a; }
EOC
red jsdoc/require-throws .; rm src/nothrows.mjs
cat > src/float.ts <<'EOC'
/** Pending. */
export const p = (): Promise<void> => Promise.resolve();
/**
 * Calls it.
 * @returns nothing
 */
export function g(): void { p(); }
EOC
red @typescript-eslint/no-floating-promises .; rm src/float.ts
cat > src/undef.mjs <<'EOC'
console.log(process.argv, notDefinedAnywhere);
EOC
red no-undef .; rm src/undef.mjs
good .

# the ratchet: existing findings are suppressed once, a new one is red, a fixed one is pruned
cat > src/old.mjs <<'EOC'
export function old() { return 1; }
EOC
red jsdoc/require-jsdoc .
npx eslint . --suppress-all >/dev/null 2>&1 || true
[ -s eslint-suppressions.json ] || fail "--suppress-all wrote no eslint-suppressions.json"
good .
cat > src/fresh.mjs <<'EOC'
export function fresh() { return 2; }
EOC
red jsdoc/require-jsdoc .; rm src/fresh.mjs
good .
cat > src/old.mjs <<'EOC'
/**
 * Fixed.
 * @returns {number} one
 */
export function old() { return 1; }
EOC
if lint .; then fail "a suppression that no longer occurs passed (it must be red until pruned)"; fi
grep -qi 'suppress' out.txt || { cat out.txt; fail "stale suppression: no message about suppressions"; }
npx eslint . --prune-suppressions >/dev/null 2>&1 || fail "--prune-suppressions failed"
good .
grep -q 'old.mjs' eslint-suppressions.json && fail "pruned file still lists old.mjs"
echo "eslint-standard: GREEN"
