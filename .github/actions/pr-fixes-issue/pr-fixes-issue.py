#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""pr-fixes-issue: a pull request body carries a closing reference.

The CURRENT body is read from the API (GET repos/{PR_REPO}/pulls/{PR_NUMBER} through urllib at GITHUB_API_URL, default https://api.github.com, with the job token, read-only; no gh CLI is needed, the self-hosted runner has none), not
from the event payload: editing a body starts no run with the default event types, and a re-run replays the OLD payload, so a
payload body would keep a fixed pull request red. PR_NUMBER and PR_REPO come from the environment; the body is data, never
spliced into a shell line. A closing reference is a
GitHub closing keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, any case, an optional colon)
followed by `#N` (this repository), `Open-Mixer/<repo>#N` or `FreeREAC/<repo>#N`; owners compare case-insensitively, as GitHub links them. Fenced code blocks and inline code are
removed first: GitHub links no keyword written in code, so a reference quoted there fixes nothing. A closing keyword followed by
a reference to any other owner is refused by name, even beside a good one.

Exit 0 good, 1 refused (the missing piece is named), 2 the body could not be read (never a pass).
"""
import json
import os
import re
import sys
import urllib.request

KEYWORD = r'(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)'
OWNERS = ('open-mixer', 'freereac')
REPO = r'[A-Za-z0-9._-]+'
# a closing keyword, then ANY owner/repo#N or #N; the owner is judged afterwards so a foreign one is named
CLOSING = re.compile(r'(?<![A-Za-z0-9_])' + KEYWORD + r':?[ \t]+(?:([A-Za-z0-9_.-]+)/(' + REPO + r'))?#([0-9]+)(?![A-Za-z0-9_])', re.I)
FENCE = re.compile(r'^[ \t]{0,3}(`{3,}|~{3,}).*?^[ \t]{0,3}\1[`~]*[ \t]*$', re.M | re.S)
INLINE = re.compile(r'`[^`\n]*`')


def strip_code(body):
    body = body.replace('\r\n', '\n')
    body = FENCE.sub('', body)
    # an unclosed fence runs to the end of the body
    body = re.sub(r'^[ \t]{0,3}(`{3,}|~{3,}).*\Z', '', body, flags=re.M | re.S)
    return INLINE.sub('', body)


def judge(body):
    """-> (good refs, foreign refs) found outside code."""
    good, foreign = [], []
    for m in CLOSING.finditer(strip_code(body)):
        owner, repo, num = m.group(1), m.group(2), m.group(3)
        if owner is None:
            good.append('#' + num)
        elif owner.lower() in OWNERS:
            good.append('%s/%s#%s' % (owner, repo, num))
        else:
            foreign.append('%s/%s#%s' % (owner, repo, num))
    return good, foreign


def read_body(repo, number):
    """The pull request's current body from the API, or None when it cannot be read."""
    api = os.environ.get('GITHUB_API_URL') or 'https://api.github.com'
    req = urllib.request.Request('%s/repos/%s/pulls/%s' % (api.rstrip('/'), repo, number), headers={
        'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'pr-fixes-issue'})
    token = os.environ.get('GH_TOKEN')
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode('utf-8')).get('body') or ''
    except (OSError, ValueError, AttributeError) as e:
        print('pr-fixes-issue: the API did not give the body of %s#%s (a private repository needs the caller to grant '
              'pull-requests: read): %s' % (repo, number, e), file=sys.stderr)
        return None


def main():
    number, repo = os.environ.get('PR_NUMBER'), os.environ.get('PR_REPO')
    if not number or not repo:
        print('pr-fixes-issue: no pull request in the event (PR_NUMBER or PR_REPO is empty): the body cannot be read', file=sys.stderr)
        return 2
    body = read_body(repo, number)
    if body is None:
        return 2
    good, foreign = judge(body)
    for f in foreign:
        print('pr-fixes-issue: %s is not an Open-Mixer or FreeREAC reference; only those two owners are accepted' % f)
    if good and not foreign:
        print('pr-fixes-issue: pull request #%s fixes %s' % (os.environ['PR_NUMBER'], ', '.join(good)))
        return 0
    if not good:
        print('pr-fixes-issue: pull request #%s has no closing reference: write "Fixes #N" (or "Fixes Open-Mixer/<repo>#N", '
              '"Fixes FreeREAC/<repo>#N") in the body, outside any code block; closes, closed, fix, fixed, resolve, resolves, '
              'resolved also count' % os.environ['PR_NUMBER'])
    return 1


if __name__ == '__main__':
    sys.exit(main())
