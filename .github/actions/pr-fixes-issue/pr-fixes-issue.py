#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""pr-fixes-issue: a pull request body carries a closing reference.

The body arrives in the environment (PR_BODY) and is read as data, never spliced into a shell line. A closing reference is a
GitHub closing keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, any case, an optional colon)
followed by `#N` (this repository), `Open-Mixer/<repo>#N` or `FreeREAC/<repo>#N`. Fenced code blocks and inline code are
removed first: GitHub links no keyword written in code, so a reference quoted there fixes nothing. A closing keyword followed by
a reference to any other owner is refused by name, even beside a good one.

Exit 0 good, 1 refused (the missing piece is named), 2 the body could not be read (never a pass).
"""
import os
import re
import sys

KEYWORD = r'(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)'
OWNERS = ('Open-Mixer', 'FreeREAC')
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
        elif owner in OWNERS:
            good.append('%s/%s#%s' % (owner, repo, num))
        else:
            foreign.append('%s/%s#%s' % (owner, repo, num))
    return good, foreign


def main():
    if not os.environ.get('PR_NUMBER'):
        print('pr-fixes-issue: no pull request in the event (PR_NUMBER is empty): the body cannot be read', file=sys.stderr)
        return 2
    if 'PR_BODY' not in os.environ:
        print('pr-fixes-issue: PR_BODY is not set: the body cannot be read', file=sys.stderr)
        return 2
    good, foreign = judge(os.environ['PR_BODY'])
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
