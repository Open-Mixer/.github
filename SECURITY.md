<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Copyright (C) 2026 Pau Aliagas -->
# Security policy

This policy covers every repository of the FreeMixer organisation that has no `SECURITY.md` of its own.

## Supported versions

Each package is supported at its latest minor release. A fix ships as a patch release of that minor;
older minors get no fixes. Please check that the problem is still there in the latest release before
you report it.

## Reporting a vulnerability

Report it privately on GitHub: open the repository's **Security** tab and choose **Report a
vulnerability**. Please do not open a public issue, pull request or discussion for it.

A useful report names the package and its version, the input an attacker controls, and how to
reproduce the problem. A crashing input or a short program is welcome.

## What to expect

- An acknowledgement on the private report.
- Once the problem is confirmed, a fix in a patch release of the latest minor.
- A GitHub security advisory on the repository when the fix is released, crediting the reporter
  unless they ask otherwise.

## Scope

In scope: the packages these repositories build, their libraries, daemons, tools and plugins, and
their RPM and DEB packaging. The web sites are out of scope.

Where a repository has a `docs/threat-model.md`, it lists the inputs that code treats as untrusted.
