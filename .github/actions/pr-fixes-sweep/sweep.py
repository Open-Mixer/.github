#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""pr-fixes-sweep: a read-only report of work not tied to an issue or a pull request.

Over the repositories of Open-Mixer and FreeREAC it can read (archived ones skipped), it lists
  (a) OPEN ISSUES WITH NO LINKED PULL REQUEST for 7 days: the issue was created 7 or more days ago and the GraphQL field
      Issue.closedByPullRequestsReferences (the "linked pull requests" of the issue page: a closing keyword in a pull
      request body or the sidebar link, open or merged, not a closed unmerged one) has totalCount 0 now;
  (b) BRANCHES WITH NO OPEN PULL REQUEST AND NO ISSUE REFERENCE: no open pull request has the branch as its head, and neither the
      branch name nor the message of its last commit names an issue. A name names one by `#N`, `issue-N`, or a number set off by
      '/', '-' or '_' (lane/foo-123-bar); a message by `#N`, `Open-Mixer/<repo>#N` or `FreeREAC/<repo>#N`. Skipped: the default
      branch, main, openmixer-v*, release/*, settle/*, gh-pages.
It WRITES NOTHING anywhere but its own output (the job summary): every GitHub call is a read (GET, or a GraphQL query), paced to
one call per second.

  sweep.py run --owner Open-Mixer --owner FreeREAC     read GitHub with `gh api`, print the report
  sweep.py classify FIXTURE.json [--now ISO]            the classifier alone over a fixture (no network)
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

STALE_DAYS = 7
EXEMPT = (re.compile(r'^main$'), re.compile(r'^openmixer-v'), re.compile(r'^release/'), re.compile(r'^settle/'), re.compile(r'^gh-pages$'))
NAME_REF = re.compile(r'(?:#|issue-)[0-9]+|(?:^|[/_-])[0-9]+(?=$|[/_-])', re.I)
MSG_REF = re.compile(r'(?<![A-Za-z0-9_/])(?:(?:Open-Mixer|FreeREAC)/[A-Za-z0-9._-]+)?#[0-9]+(?![A-Za-z0-9_])')


def parse_time(s):
    return datetime.fromisoformat(s.replace('Z', '+00:00'))


def unlinked_issues(issues, now):
    """Open issues created STALE_DAYS or more days ago with no linked pull request."""
    out = []
    for i in issues:
        if i.get('state', 'OPEN') != 'OPEN' or i.get('linked_prs', 0) > 0:
            continue
        if now - parse_time(i['created_at']) >= timedelta(days=STALE_DAYS):
            out.append(i)
    return sorted(out, key=lambda i: i['number'])


def untied_branches(branches, open_pr_heads, default_branch):
    """Branches with no open pull request and no issue reference in the name or the last commit message."""
    out = []
    for b in branches:
        n = b['name']
        if n == default_branch or any(p.search(n) for p in EXEMPT):
            continue
        if n in open_pr_heads or NAME_REF.search(n) or MSG_REF.search(b.get('message', '')):
            continue
        out.append(b)
    return sorted(out, key=lambda b: b['name'])


def classify(repos, now):
    rows_i, rows_b, unread = [], [], []
    for r in repos:
        if r.get('error'):
            unread.append(r['repo'])
            continue
        for i in unlinked_issues(r['issues'], now):
            rows_i.append((r['repo'], i))
        for b in untied_branches(r['branches'], set(r['open_pr_heads']), r['default_branch']):
            rows_b.append((r['repo'], b))
    return rows_i, rows_b, unread


def cell(s):
    return s.replace('|', '\\|').replace('\n', ' ')


def report(repos, now):
    rows_i, rows_b, unread = classify(repos, now)
    o = ['# pr-fixes-sweep', '',
         'Read-only. %d repositories read, %d unreadable. Issues: open %d or more days with no linked pull request. '
         'Branches: no open pull request and no issue reference.' % (len(repos) - len(unread), len(unread), STALE_DAYS), '',
         '## Open issues with no linked pull request for %d days (%d)' % (STALE_DAYS, len(rows_i)), '']
    if rows_i:
        o += ['| issue | opened | title |', '| --- | --- | --- |']
        o += ['| %s#%d | %s | %s |' % (r, i['number'], i['created_at'][:10], cell(i['title'])) for r, i in rows_i]
    else:
        o.append('None.')
    o += ['', '## Branches with no open pull request and no issue reference (%d)' % len(rows_b), '']
    if rows_b:
        o += ['| repository | branch | last commit |', '| --- | --- | --- |']
        o += ['| %s | %s | %s |' % (r, cell(b['name']), cell(b.get('message', '').split('\n')[0])) for r, b in rows_b]
    else:
        o.append('None.')
    if unread:
        o += ['', '## Repositories that could not be read (%d)' % len(unread), ''] + ['- ' + r for r in unread]
    return '\n'.join(o) + '\n', len(repos) - len(unread)


# ---- the reader: GETs and GraphQL queries only, one call per second ----
_last = [0.0]


def gh(args):
    wait = 1.0 - (time.monotonic() - _last[0])
    if wait > 0:
        time.sleep(wait)
    _last[0] = time.monotonic()
    p = subprocess.run(['gh', 'api'] + args, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or 'gh api failed')
    return json.loads(p.stdout)


def graphql(query, **vars):
    a = ['graphql', '-f', 'query=' + query]
    for k, v in vars.items():
        a += ['-f', '%s=%s' % (k, v)]
    r = gh(a)
    if r.get('errors'):
        raise RuntimeError(json.dumps(r['errors']))
    return r['data']


Q_ISSUES = '''query($o:String!,$n:String!,$after:String){repository(owner:$o,name:$n){issues(states:OPEN,first:100,after:$after){
pageInfo{hasNextPage endCursor} nodes{number title createdAt closedByPullRequestsReferences(first:1){totalCount}}}}}'''
Q_PRS = '''query($o:String!,$n:String!,$after:String){repository(owner:$o,name:$n){pullRequests(states:OPEN,first:100,after:$after){
pageInfo{hasNextPage endCursor} nodes{headRefName}}}}'''
Q_DEFAULT = 'query($o:String!,$n:String!){repository(owner:$o,name:$n){defaultBranchRef{name}}}'
Q_REFS = '''query($o:String!,$n:String!,$after:String){repository(owner:$o,name:$n){
refs(refPrefix:"refs/heads/",first:100,after:$after){pageInfo{hasNextPage endCursor}
nodes{name target{... on Commit{message}}}}}}'''
Q_REPOS = '''query($o:String!,$after:String){repositoryOwner(login:$o){repositories(first:100,after:$after,isArchived:false){
pageInfo{hasNextPage endCursor} nodes{name}}}}'''


def paged(query, path, **vars):
    after, out = '', []
    while True:
        d = graphql(query, after=after, **vars) if after else graphql(query, **vars)
        for k in path:
            d = d[k]
        out += d['nodes']
        if not d['pageInfo']['hasNextPage']:
            return out
        after = d['pageInfo']['endCursor']


def read_repo(owner, name):
    try:
        issues = [{'number': n['number'], 'title': n['title'], 'created_at': n['createdAt'],
                   'linked_prs': n['closedByPullRequestsReferences']['totalCount']}
                  for n in paged(Q_ISSUES, ('repository', 'issues'), o=owner, n=name)]
        heads = [n['headRefName'] for n in paged(Q_PRS, ('repository', 'pullRequests'), o=owner, n=name)]
        refs = paged(Q_REFS, ('repository', 'refs'), o=owner, n=name)
        d = graphql(Q_DEFAULT, o=owner, n=name)['repository']['defaultBranchRef']
        return {'repo': '%s/%s' % (owner, name), 'issues': issues, 'open_pr_heads': heads,
                'default_branch': d['name'] if d else 'main',
                'branches': [{'name': r['name'], 'message': (r.get('target') or {}).get('message', '')} for r in refs]}
    except RuntimeError as e:
        print('pr-fixes-sweep: %s/%s unreadable: %s' % (owner, name, e), file=sys.stderr)
        return {'repo': '%s/%s' % (owner, name), 'error': str(e)}


def run(owners):
    repos = []
    for o in owners:
        try:
            names = [n['name'] for n in paged(Q_REPOS, ('repositoryOwner', 'repositories'), o=o)]
        except RuntimeError as e:
            print('pr-fixes-sweep: owner %s unreadable: %s' % (o, e), file=sys.stderr)
            repos.append({'repo': o + '/*', 'error': str(e)})
            continue
        repos += [read_repo(o, n) for n in sorted(names)]
    return repos


def emit(text):
    s = os.environ.get('GITHUB_STEP_SUMMARY')
    if s:
        with open(s, 'a') as f:
            f.write(text)
    sys.stdout.write(text)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run')
    r.add_argument('--owner', action='append', required=True)
    c = sub.add_parser('classify')
    c.add_argument('fixture')
    c.add_argument('--now', default=None)
    a = ap.parse_args()
    if a.cmd == 'classify':
        repos = json.load(open(a.fixture))
        now = parse_time(a.now) if a.now else datetime.now(timezone.utc)
    else:
        repos, now = run(a.owner), datetime.now(timezone.utc)
    text, read = report(repos, now)
    emit(text)
    return 0 if read else 2


if __name__ == '__main__':
    sys.exit(main())
