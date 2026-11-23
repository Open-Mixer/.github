<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<!-- Copyright (C) 2026 Pau Aliagas -->
# The shared ESLint config

`.github/eslint/openmixer.config.mjs` is the one flat config every Open-Mixer repository uses for its JS and TS. It
uses the standard tools only: `@eslint/js` recommended, `typescript-eslint` (`recommendedTypeChecked` for TypeScript,
with `parserOptions.projectService`; `recommended` for plain JS) and `eslint-plugin-jsdoc`, which requires a JSDoc block
on every EXPORTED function with a `@param` for every parameter, `@returns` when it returns a value and `@throws` when
its body throws.

## A repository uses it

1. Pin the exact versions listed in `.github/eslint/package.json` in the repository's own `devDependencies`; the config
   resolves the plugins from the repository it runs in.
2. Add an `eslint.config.mjs` that imports the shared file from a checkout of this repository and spreads it, with the
   repository's own `ignores`.
3. Create the ratchet once with `eslint . --suppress-all`, which writes `eslint-suppressions.json`: the findings that
   exist today, per file and rule.

From then on a NEW finding is red, a FIXED finding left in the file is red until `eslint . --prune-suppressions` removes
it, and a new file starts with none. The count only falls; no checker of ours does the counting.

`tests/eslint-standard.sh` proves each of these against a scratch project with the pinned versions.
