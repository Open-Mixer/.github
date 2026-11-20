// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Pau Aliagas
//
// The ESLint flat config every Open-Mixer repository uses for its JS and TS: the standard tools only.
//   - @eslint/js recommended;
//   - typescript-eslint recommendedTypeChecked for .ts/.mts/.cts (parserOptions.projectService: the nearest tsconfig),
//     and typescript-eslint recommended (no type information) for .js/.mjs/.cjs, which no tsconfig need cover;
//   - eslint-plugin-jsdoc: require-jsdoc on EXPORTED functions only (publicOnly), require-param, require-returns,
//     require-throws.
// The ratchet is ESLint's own bulk suppressions (eslint-suppressions.json), not a checker of ours. docs/eslint.md says
// how a repository consumes this file.
//
// The plugins are resolved from the CONSUMING repository (the directory eslint runs in), so a repository pins exact
// versions in its own devDependencies (.github/eslint/package.json lists the ones this file is tested with).
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const req = createRequire(path.join(process.cwd(), 'package.json'));

/**
 * Imports a package installed in the consuming repository.
 * @param {string} name the package name
 * @returns {Promise<any>} its default export, or its namespace when it has none
 * @throws {Error} when the package is not installed there
 */
async function load(name) {
  let file;
  try {
    file = req.resolve(name);
  } catch (e) {
    throw new Error(`openmixer.config.mjs: ${name} is not installed in ${process.cwd()} (pin it in devDependencies): ${e.message}`);
  }
  const mod = await import(pathToFileURL(file).href);
  return mod.default ?? mod;
}

const js = await load('@eslint/js');
const tseslint = await load('typescript-eslint');
const jsdoc = await load('eslint-plugin-jsdoc');
const globals = await load('globals');

const TS = ['**/*.ts', '**/*.mts', '**/*.cts'];
const JS = ['**/*.js', '**/*.mjs', '**/*.cjs'];

/** @type {import('eslint').Linter.Config[]} */
export default [
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked.map((c) => ({ ...c, files: TS })),
  ...tseslint.configs.recommended.map((c) => ({ ...c, files: JS })),
  {
    files: TS,
    languageOptions: { parserOptions: { projectService: true } },
  },
  {
    // typescript-eslint's eslint-recommended set switches no-undef off (tsc covers it in .ts); a .js file has no tsc
    files: JS,
    rules: { 'no-undef': 'error' },
  },
  {
    files: [...TS, ...JS],
    languageOptions: { globals: { ...globals.node, ...globals.es2025 } },
    plugins: { jsdoc },
    rules: {
      'jsdoc/require-jsdoc': ['error', {
        publicOnly: true,
        require: { FunctionDeclaration: true, ArrowFunctionExpression: true, FunctionExpression: true, MethodDefinition: false, ClassDeclaration: false },
      }],
      'jsdoc/require-param': 'error',
      'jsdoc/require-returns': 'error',
      'jsdoc/require-throws': 'error',
    },
  },
];
