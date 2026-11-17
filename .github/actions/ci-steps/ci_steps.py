#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Pau Aliagas <linuxnow@gmail.com>
"""ci_steps.py: which commands of a workflow's steps really run, and which can fail the job.

A check that sits in no step pins nothing, and neither does one whose failure the step swallows. This reader takes a
workflow file and says, per job, per step and per command of every `run:` script:

  runs   always       every green run of the step executed it
         conditional  the step can go green without having executed it
         never        it is written as a command and cannot execute
  gates  whether its failure fails the job

The workflow is read with PyYAML, as the runner reads it. Each script is read as the shell reads it: tokens, quotes,
heredocs, lists, pipelines, groups, substitutions, and the options (`-e`, pipefail, `-n`) of the shell the step runs
under. arms.yml beside this file is the table that holds the reader to its rules.

  ci_steps.py WORKFLOW...                        the report
  ci_steps.py --json WORKFLOW...                 the same as JSON, for a check that asks its own question
  ci_steps.py --require 'CMD [ARG...]' ... WORKFLOW...
        exit 1 unless, in one of the workflows, a command whose command word is CMD (a path may be longer on the left)
        and whose arguments hold every ARG runs always and gates; --conditional also takes one that runs conditionally

Exit 0, 1 (a requirement is not met), 2 (usage, or a workflow that cannot be read).
"""
import argparse
import copy
import json
import re
import shlex
import sys
from types import SimpleNamespace as NS

import yaml

# what GitHub runs for a `shell:` value (workflow syntax, jobs.<job_id>.steps[*].shell); '' is a step with no shell
SHELL_TEMPLATES = {
    "": "bash -e {0}",
    "bash": "bash --noprofile --norc -eo pipefail {0}",
    "sh": "sh -e {0}",
}
# the shells whose scripts are read; a step under any other (python, pwsh, cmd) is reported unread
SHELLS = ("bash", "sh", "dash")
# words before the command word that run it: each maps to the options of its own that take a value
PREFIXES = {
    "env": ("-u", "--unset", "-C", "--chdir"),
    "command": (),
    "timeout": ("-k", "--kill-after", "-s", "--signal"),
    "exec": ("-a",),
    "time": (),
    "sudo": ("-u", "--user", "-g", "--group"),
    "source": (),
    ".": (),
}
ASSIGNMENT = re.compile(r"[A-Za-z_]\w*(\[[^\]]*\])?\+?=")
REDIRECTION = re.compile(r"(\d+|\{\w+\})?(&>>|&>|<<<|<<-|<<|<>|<&|>&|>>|>\||<|>)")
OPERATORS = ("&&", "||", ";;&", ";;", ";&", "|&", ";", "&", "|", "(", ")")
CLOSERS = ("then", "elif", "else", "fi", "do", "done", "esac", "}")


class Unread(Exception):
    """The script is not one this reader can read: nothing is said of its commands."""


class Lexer:
    """The script as the shell's tokens: words (with what they hold once quotes are removed, and the substitutions
    inside them), operators, redirections (a heredoc with its body) and newlines."""

    def __init__(self, text, start=0, line=1, until_paren=False):
        self.s, self.i, self.line, self.until_paren = text, start, line, until_paren
        self.toks, self.pending, self.delimiter_for = [], [], None

    def fail(self, what):
        raise Unread("line %d: %s" % (self.line, what))

    def emit(self, kind, text, **more):
        tok = NS(kind=kind, text=text, line=self.line, **more)
        self.toks.append(tok)
        return tok

    def run(self):
        s, depth, cases = self.s, 0, []
        while self.i < len(s):
            c = s[self.i]
            if s.startswith("\\\n", self.i):
                self.i += 2
                self.line += 1
            elif c in " \t":
                self.i += 1
            elif c == "\n":
                self.emit("nl", "\n")
                self.i += 1
                self.line += 1
                self.heredocs()
            elif c == "#":
                while self.i < len(s) and s[self.i] != "\n":
                    self.i += 1
            elif s.startswith("((", self.i) and self.arithmetic():
                pass
            elif self.redirection():
                pass
            elif c in ";&|()":
                op = next(o for o in OPERATORS if s.startswith(o, self.i))
                if op == "(":
                    depth += 1
                elif op == ")":
                    if cases and cases[-1] == depth:
                        pass  # the parenthesis that ends a case pattern
                    elif depth == 0 and self.until_paren:
                        self.i += 1
                        return self
                    else:
                        depth -= 1
                self.emit("op", op)
                self.i += len(op)
            else:
                tok = self.word()
                if tok.bare and tok.text == "case":
                    cases.append(depth)
                elif tok.bare and tok.text == "esac" and cases:
                    cases.pop()
        if self.until_paren:
            self.fail("a `$(` that never closes")
        return self

    def arithmetic(self):
        """`(( ... ))` is one word, never a heredoc start or a subshell; `((a); b)` is two subshells."""
        depth, j = 0, self.i
        while j < len(self.s):
            if self.s[j] == "(":
                depth += 1
            elif self.s[j] == ")":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if j >= len(self.s) or self.s[j - 1] != ")":
            return False
        text = self.s[self.i:j + 1]
        self.emit("word", text, value=text, bare=False, subs=[], quoted=False, arithmetic=True)
        self.line += text.count("\n")
        self.i = j + 1
        return True

    def redirection(self):
        m = REDIRECTION.match(self.s, self.i)
        if not m or (m.group(2) in "<>" and self.s[m.end():m.end() + 1] == "("):
            return False
        tok = self.emit("redir", m.group(2), heredoc=None)
        self.i = m.end()
        if m.group(2) in ("<<", "<<-"):
            self.delimiter_for = tok
        return True

    def heredocs(self):
        """After the newline that ends a line with heredoc starts: their bodies, in order, each up to its delimiter."""
        for tok, delimiter, quoted in self.pending:
            body, first = [], self.line
            while self.i < len(self.s):
                end = self.s.find("\n", self.i)
                end = len(self.s) if end < 0 else end
                text = self.s[self.i:end]
                self.i = min(end + 1, len(self.s))
                self.line += 1
                if (text.lstrip("\t") if tok.text == "<<-" else text) == delimiter:
                    break
                body.append(text)
            tok.heredoc = NS(body="\n".join(body), quoted=quoted, line=first)
        self.pending = []

    def word(self):
        s, start, line = self.s, self.i, self.line
        value, subs, quoted, expands = [], [], False, False
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\n":
                break
            if c in ";&|()<>":
                if c in "<>" and s[self.i + 1:self.i + 2] == "(":  # a process substitution
                    at = self.i
                    self.i += 2
                    subs.append(self.substitution())
                    value.append(s[at:self.i])
                    expands = True
                    continue
                if c == "(" and ASSIGNMENT.fullmatch(s, start, self.i):  # an array assignment
                    at = self.i
                    self.balanced("(", ")")
                    value.append(s[at:self.i])
                    expands = True
                    continue
                break
            if c == "\\":
                if s[self.i + 1:self.i + 2] == "\n":
                    self.line += 1
                else:
                    value.append(s[self.i + 1:self.i + 2])
                    quoted = True
                self.i += 2
            elif c == "'":
                end = s.find("'", self.i + 1)
                if end < 0:
                    self.fail("a single quote that never closes")
                value.append(s[self.i + 1:end])
                self.line += s.count("\n", self.i, end)
                self.i, quoted = end + 1, True
            elif c == '"':
                self.i += 1
                expands = self.double_quoted(value, subs) or expands
                quoted = True
            elif c == "`":
                subs.append(self.backticks(value))
                expands = True
            elif c == "$":
                expands = self.dollar(value, subs) or expands
            else:
                value.append(c)
                self.i += 1
        raw = s[start:self.i]
        tok = NS(kind="word", text=raw, line=line, value="".join(value), bare=not quoted and not expands, subs=subs,
                 quoted=quoted, arithmetic=False)
        self.toks.append(tok)
        if self.delimiter_for is not None:
            self.pending.append((self.delimiter_for, tok.value, quoted))
            self.delimiter_for = None
        return tok

    def balanced(self, opener, closer):
        """Skip from the opener at the cursor to its closer, quotes respected."""
        depth, s = 0, self.s
        while self.i < len(s):
            c = s[self.i]
            if c == "\\":
                self.i += 1
            elif c == "'":
                end = s.find("'", self.i + 1)
                if end < 0:
                    self.fail("a single quote that never closes")
                self.line += s.count("\n", self.i, end)
                self.i = end
            elif c == "\n":
                self.line += 1
            elif c == opener:
                depth += 1
            elif c == closer:
                depth -= 1
                if depth == 0:
                    self.i += 1
                    return
            self.i += 1
        self.fail("a `%s` that never closes" % opener)

    def substitution(self):
        """The tokens of a `$( ... )` whose first character is at the cursor; the cursor ends after its parenthesis."""
        sub = Lexer(self.s, self.i, self.line, until_paren=True).run()
        self.i, self.line = sub.i, sub.line
        return sub.toks

    def backticks(self, value):
        s, at = self.s, self.i
        j = at + 1
        while j < len(s) and s[j] != "`":
            j += 2 if s[j] == "\\" else 1
        if j >= len(s):
            self.fail("a backtick that never closes")
        value.append(s[at:j + 1])
        toks = Lexer(re.sub(r"\\([`\\$])", r"\1", s[at + 1:j]), 0, self.line).run().toks
        self.line += s.count("\n", at, j)
        self.i = j + 1
        return toks

    def dollar(self, value, subs):
        """An expansion at the cursor. -> whether it was one (a lone `$` is text)."""
        s, at = self.s, self.i
        if s.startswith("${{", at):  # an expression the runner fills in before the shell reads the script
            end = s.find("}}", at)
            if end < 0:
                self.fail("a `${{` that never closes")
            self.i = end + 2
        elif s.startswith("$((", at):
            self.i += 1
            self.balanced("(", ")")
        elif s.startswith("$(", at):
            self.i += 2
            subs.append(self.substitution())
        elif s.startswith("${", at):
            self.i += 1
            self.braced(subs)
        elif s.startswith("$'", at):
            j = at + 2
            while j < len(s) and s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            if j >= len(s):
                self.fail("a `$'` that never closes")
            self.line += s.count("\n", at, j)
            self.i = j + 1
        else:
            value.append("$")
            self.i += 1
            return re.match(r"[A-Za-z_0-9?#@*!$-]", s[self.i:self.i + 1]) is not None
        value.append(s[at:self.i])
        return True

    def braced(self, subs):
        """`${ ... }` from its brace at the cursor: skipped, the substitutions inside it kept."""
        s, depth = self.s, 0
        while self.i < len(s):
            c = s[self.i]
            if c == "\\":
                self.i += 2
                continue
            if s.startswith("$(", self.i) and not s.startswith("$((", self.i):
                self.i += 2
                subs.append(self.substitution())
                continue
            if c == "`":
                subs.append(self.backticks([]))
                continue
            if c == "\n":
                self.line += 1
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    self.i += 1
                    return
            self.i += 1
        self.fail("a `${` that never closes")

    def double_quoted(self, value, subs):
        """From after the opening quote to after the closing one. -> whether anything inside expands."""
        s, expands = self.s, False
        while self.i < len(s):
            c = s[self.i]
            if c == '"':
                self.i += 1
                return expands
            if c == "\\" and s[self.i + 1:self.i + 2] in ('"', "\\", "$", "`", "\n"):
                if s[self.i + 1] == "\n":
                    self.line += 1
                else:
                    value.append(s[self.i + 1])
                self.i += 2
            elif c == "`":
                subs.append(self.backticks(value))
                expands = True
            elif c == "$":
                expands = self.dollar(value, subs) or expands
            else:
                if c == "\n":
                    self.line += 1
                value.append(c)
                self.i += 1
        self.fail("a double quote that never closes")
        return expands


def body_substitutions(heredoc):
    """The `$( )` and backtick substitutions of an unquoted heredoc body: the shell runs them."""
    lex, subs, s = Lexer(heredoc.body, 0, heredoc.line), [], heredoc.body
    while lex.i < len(s):
        c = s[lex.i]
        if c == "\\":
            lex.i += 2
        elif c == "`":
            subs.append(lex.backticks([]))
        elif c == "$":
            lex.dollar([], subs)
        else:
            if c == "\n":
                lex.line += 1
            lex.i += 1
    return subs


def short(text):
    text = " ".join(text.split())
    return text if len(text) <= 60 else text[:57] + "..."


class Parser:
    """Tokens to lists of and-or lists of pipelines of commands, compound commands with their bodies."""

    def __init__(self, toks):
        self.t, self.p = toks, 0
        self.end = NS(kind="eof", text="the end of the script", line=toks[-1].line if toks else 1, bare=False)

    def peek(self):
        return self.t[self.p] if self.p < len(self.t) else self.end

    def take(self):
        tok = self.peek()
        self.p += 1
        return tok

    def is_op(self, *ops):
        tok = self.peek()
        return tok.kind == "op" and tok.text in ops

    def is_word(self, *words):
        tok = self.peek()
        return tok.kind == "word" and tok.bare and tok.text in words

    def expect_word(self, word):
        if not self.is_word(word):
            raise Unread("line %d: `%s` where `%s` belongs" % (self.peek().line, self.peek().text.strip() or "newline", word))
        self.p += 1

    def newlines(self):
        while self.peek().kind == "nl":
            self.p += 1

    def since(self, start):
        return short(" ".join(t.text for t in self.t[start:self.p] if t.kind != "nl"))

    def script(self):
        items = self.items()
        if self.peek().kind != "eof":
            raise Unread("line %d: `%s` closes nothing" % (self.peek().line, self.peek().text))
        return items

    def items(self):
        """Commands up to a word or operator that closes the enclosing construct: [(and-or list, backgrounded)]."""
        out = []
        while True:
            while self.peek().kind == "nl" or self.is_op(";"):
                self.p += 1
            if self.peek().kind == "eof" or self.is_op(")", ";;", ";&", ";;&") or self.is_word(*CLOSERS):
                return out
            node = self.and_or()
            background = self.is_op("&")
            if background:
                self.p += 1
            out.append((node, background))

    def and_or(self):
        start = self.p
        elems, ops = [self.pipeline()], []
        while self.is_op("&&", "||"):
            ops.append(self.take().text)
            self.newlines()
            elems.append(self.pipeline())
        return NS(elems=elems, ops=ops, text=self.since(start))

    def pipeline(self):
        negated, start = False, self.p
        while self.is_word("!", "time"):
            if self.take().text == "!":
                negated = not negated
            elif self.peek().kind == "word" and self.peek().text == "-p":
                self.p += 1
        cmds = [self.command()]
        while self.is_op("|", "|&"):
            self.p += 1
            self.newlines()
            cmds.append(self.command())
        return NS(negated=negated, cmds=cmds, text=self.since(start))

    def command(self):
        tok = self.peek()
        if self.is_op("("):
            self.p += 1
            body = self.items()
            if not self.is_op(")"):
                raise Unread("line %d: a `(` that never closes" % tok.line)
            self.p += 1
            node = NS(kind="subshell", body=body, line=tok.line)
        elif self.is_word("{"):
            self.p += 1
            body = self.items()
            self.expect_word("}")
            node = NS(kind="group", body=body, line=tok.line)
        elif self.is_word("if"):
            node = self.if_command()
        elif self.is_word("while", "until"):
            self.p += 1
            cond = self.items()
            self.expect_word("do")
            body = self.items()
            self.expect_word("done")
            node = NS(kind="loop", cond=cond, body=body, words=None, line=tok.line)
        elif self.is_word("for", "select"):
            node = self.for_command()
        elif self.is_word("case"):
            node = self.case_command()
        elif self.is_word("function"):
            self.p += 1
            name = self.take()
            if self.is_op("("):
                self.p += 2
            self.newlines()
            return NS(kind="function", name=name.text, body=self.command(), line=tok.line)
        elif self.is_word("[["):
            words = []
            while not self.is_word("]]"):
                if self.peek().kind == "eof":
                    raise Unread("line %d: a `[[` that never closes" % tok.line)
                words.append(self.take())
            self.p += 1
            node = NS(kind="test", words=words, line=tok.line)
        else:
            return self.simple()
        node.redirs = self.redirections()
        return node

    def redirections(self):
        out = []
        while self.peek().kind == "redir":
            op = self.take()
            if self.peek().kind != "word":
                raise Unread("line %d: `%s` with nothing after it" % (op.line, op.text))
            out.append((op, self.take()))
        return out

    def if_command(self):
        line, clauses, otherwise = self.take().line, [], None
        while True:
            start = self.p
            cond = self.items()
            text = self.since(start)
            self.expect_word("then")
            clauses.append((cond, self.items(), text))
            if not self.is_word("elif"):
                break
            self.p += 1
        if self.is_word("else"):
            self.p += 1
            otherwise = self.items()
        self.expect_word("fi")
        return NS(kind="if", clauses=clauses, otherwise=otherwise, line=line)

    def for_command(self):
        line, words = self.take().line, None
        head = self.take()
        if head.kind != "word":
            raise Unread("line %d: a `for` with no name" % line)
        self.newlines()
        if not head.arithmetic and self.is_word("in"):
            self.p += 1
            words = []
            while self.peek().kind == "word":
                words.append(self.take())
        while self.peek().kind == "nl" or self.is_op(";"):
            self.p += 1
        self.expect_word("do")
        body = self.items()
        self.expect_word("done")
        return NS(kind="loop", cond=[], body=body, words=words, line=line)

    def case_command(self):
        line = self.take().line
        self.p += 1  # the word that is matched
        self.newlines()
        self.expect_word("in")
        arms = []
        while True:
            self.newlines()
            if self.is_word("esac"):
                self.p += 1
                return NS(kind="case", arms=arms, line=line)
            while not self.is_op(")"):
                if self.peek().kind == "eof":
                    raise Unread("line %d: a `case` that never closes" % line)
                self.p += 1
            self.p += 1
            arms.append(self.items())
            if self.is_op(";;", ";&", ";;&"):
                self.p += 1

    def simple(self):
        first, words, redirs = self.peek(), [], []
        while True:
            if self.peek().kind == "word":
                words.append(self.take())
            elif self.peek().kind == "redir":
                redirs.extend(self.redirections())
            else:
                break
            if len(words) == 1 and not redirs and self.is_op("(") and re.fullmatch(r"[\w.:-]+", words[0].text):
                self.p += 1
                if not self.is_op(")"):
                    raise Unread("line %d: `%s (` is no function and no command" % (first.line, words[0].text))
                self.p += 1
                self.newlines()
                return NS(kind="function", name=words[0].text, body=self.command(), line=first.line)
        if not words and not redirs:
            raise Unread("line %d: `%s` where a command belongs" % (first.line, first.text.strip() or "newline"))
        return NS(kind="simple", words=words, redirs=redirs, line=first.line)


def option_words(words, stop_at_long):
    """The -e, -n, pipefail and -c options at the head of a shell's or `set`'s words.
    -> {errexit, pipefail, noexec: True, False or None when not named}, whether -c was given, the words left."""
    found, string, i = {"errexit": None, "pipefail": None, "noexec": None}, False, 0
    letters = {"e": "errexit", "n": "noexec"}
    while i < len(words) and len(words[i]) > 1 and words[i][0] in "-+":
        word = words[i]
        i += 1
        if word == "--":
            break
        if word.startswith("--"):
            if stop_at_long and word in ("--rcfile", "--init-file"):
                i += 1
            continue
        on = word[0] == "-"
        for letter in word[1:]:
            if letter in letters:
                found[letters[letter]] = on
            elif letter == "c":
                string = True
            elif letter == "o" and i < len(words):
                if words[i] in found:
                    found[words[i]] = on
                i += 1
    return found, string, words[i:]


def skip_prefix(name, words):
    """The words after a prefix word and its own options, assignments and duration."""
    valued, i = PREFIXES[name], 0
    while i < len(words):
        word = words[i]
        if word == "--":
            i += 1
            break
        if word.startswith("-") and len(word) > 1:
            i += 2 if word in valued else 1
        elif name == "env" and ASSIGNMENT.match(word):
            i += 1
        else:
            break
    if name == "timeout" and i < len(words):
        i += 1  # the duration
    return words[i:]


def new_shell(program, words, said):
    found, string, rest = option_words(words, True)
    shell = NS(program="bash" if program == "bash" else "sh", errexit=bool(found["errexit"]),
               pipefail=bool(found["pipefail"]), noexec="%s only parses (-n)" % said if found["noexec"] else "",
               why="%s has no -e" % said, pipefail_why="%s has no pipefail" % said)
    return shell, string, rest


class Script:
    """One script's verdicts. The state of a shell (errexit, pipefail, noexec) changes as its `set` lines are met;
    a context says how a command at that place is reached and where its status goes."""

    def __init__(self):
        self.commands = []

    def read(self, text, shell, ctx, line=1):
        self.body(Parser(Lexer(text, 0, line).run().toks).script(), shell, ctx)

    def body(self, items, shell, ctx):
        """A list of commands: only the last one's status is the list's."""
        dead = ""
        for k, (node, background) in enumerate(items):
            c = copy.copy(ctx)
            if k < len(items) - 1:
                c.status, c.status_why = False, ""
            if dead:
                c.reach, c.reach_why = "never", dead
            if background:
                c.lost = "it is backgrounded with `&`: the step never reads its status"
            ended = self.and_or(node, shell, c)
            if ended and not dead and not background and ctx.reach == "always":
                dead = ended
        return dead

    def element_gate(self, node, i, shell, ctx):
        """Whether a failure of element i of an and-or list fails the step, and why not.
        A later `||` takes the failure unless what follows it certainly fails; errexit acts on the last element
        only; otherwise the failure is the list's status, which counts where the context says it does."""
        if ctx.lost:
            return False, ctx.lost
        last = len(node.elems) - 1
        for j in range(i + 1, last + 1):
            if node.ops[j - 1] == "||":
                kind = certain_failure(node.elems[j])
                if kind == "exit":
                    return ctx.exits, ctx.exits_why
                if kind == "status":
                    return self.element_gate(node, j, shell, ctx)
                return False, "its failure is taken by `|| %s`, which does not fail the step" % node.elems[j].text
        if shell.errexit and not ctx.ignored and i == last:
            return ctx.exits, ctx.exits_why
        if ctx.status:
            return True, ""
        if ctx.status_why:
            return False, ctx.status_why
        if not shell.errexit:
            return False, "%s, so a failure does not stop the script, and it is not the script's last command" % shell.why
        if ctx.ignored:
            return False, ctx.ignored
        return False, "errexit does not act on a command before `&&`, and the list is not the script's last command"

    def and_or(self, node, shell, ctx):
        reach, reach_why, ended = ctx.reach, ctx.reach_why, ""
        last = len(node.elems) - 1
        for i, pipe in enumerate(node.elems):
            if i and reach == "always":
                before = node.elems[i - 1].text
                if node.ops[i - 1] == "||":
                    reach, reach_why = "conditional", "it runs only when `%s` fails" % before
                elif not self.element_gate(node, i - 1, shell, kept(ctx))[0]:
                    reach, reach_why = "conditional", ("it runs only when `%s` succeeds, and the step goes on without it "
                                                       "when that fails" % before)
            gate = self.element_gate(node, i, shell, ctx)
            c = copy.copy(ctx)
            c.reach, c.reach_why = reach, reach_why
            if i < last and not c.ignored:
                c.ignored = "errexit does not act inside a command that is followed by `%s`" % node.ops[i]
            ended = self.pipeline(pipe, shell, c, gate)
        return ended if last == 0 else ""

    def pipeline(self, pipe, shell, ctx, gate):
        ended, last = "", len(pipe.cmds) - 1
        for k, cmd in enumerate(pipe.cmds):
            g, c = gate, copy.copy(ctx)
            if pipe.negated:
                g = (False, "its status is inverted by `!`")
                c.ignored = c.ignored or "errexit does not act on a command after `!`"
            elif k < last and not shell.pipefail and gate[0]:
                g = (False, "it feeds a pipe and %s: only the pipe's last command's status counts" % shell.pipefail_why)
            if last:  # every command of a pipe runs in a subshell of its own
                self.command(cmd, copy.copy(shell), c, g, own_shell=True)
            else:
                ended = self.command(cmd, shell, c, g, own_shell=False)
        return ended

    def command(self, cmd, shell, ctx, gate, own_shell):
        """One command, where `gate` says whether its failure fails the step."""
        inner = copy.copy(ctx)
        inner.status, inner.status_why = gate
        if own_shell or cmd.kind == "subshell":
            inner.exits, inner.exits_why = gate
        if cmd.kind == "function":
            self.function(cmd, shell, ctx)
            return ""
        if cmd.kind == "simple":
            return self.simple(cmd, shell, ctx, gate)
        for _, target in cmd.redirs:
            self.substitutions(target.subs, shell, ctx, None)
        if cmd.kind == "test":
            self.substitutions([s for w in cmd.words if w.kind == "word" for s in w.subs], shell, ctx, None)
        elif cmd.kind == "group":
            return self.body(cmd.body, shell, inner)
        elif cmd.kind == "subshell":
            self.body(cmd.body, copy.copy(shell), inner)
        elif cmd.kind == "if":
            self.if_command(cmd, shell, ctx, inner)
        elif cmd.kind == "loop":
            self.loop(cmd, shell, ctx, inner)
        elif cmd.kind == "case":
            for arm in cmd.arms:
                self.body(arm, shell, branch(inner, "it is in a `case` arm: it runs only when its pattern matches"))
        return ""

    def function(self, cmd, shell, ctx):
        body = branch(ctx, "it is in the body of function `%s`: it runs where the function is called" % cmd.name)
        body.status, body.status_why = False, ""
        self.command(cmd.body, shell, body, self.element_gate(NS(elems=[None], ops=[]), 0, shell, body), False)

    def if_command(self, cmd, shell, ctx, inner):
        held = []
        for n, (cond, then, text) in enumerate(cmd.clauses):
            c = condition(ctx, "it is an `if` condition: its status only picks the branch")
            if n:
                c = branch(c, "it is an `elif` condition: it runs only when the conditions before it fail")
            self.body(cond, shell, c)
            held.append(text)
            self.body(then, shell, branch(inner, "it runs only when `%s` holds" % text))
        if cmd.otherwise is not None:
            self.body(cmd.otherwise, shell, branch(inner, "it runs only when `%s` does not hold" % "`, `".join(held)))

    def loop(self, cmd, shell, ctx, inner):
        self.body(cmd.cond, shell, condition(ctx, "it is a loop condition: its status only ends the loop"))
        body = copy.copy(inner)
        body.status, body.status_why = False, "a loop keeps only its last pass's status"
        if cmd.words is not None:
            self.substitutions([s for w in cmd.words for s in w.subs], shell, ctx, None)
        if cmd.words is None or not any(w.bare for w in cmd.words):
            body = branch(body, "it is in a loop body that may run no pass")
        self.body(cmd.body, shell, body)

    def substitutions(self, subs, shell, ctx, gate):
        """The commands inside `$( )`: they run; the last one's status is the command's only for a bare assignment
        (`gate` then says where it goes), and bash clears errexit inside."""
        for n, toks in enumerate(subs):
            keeps = gate is not None and n == len(subs) - 1
            g = gate if keeps else (False, "it runs inside a substitution of another command, which drops its status")
            inner = copy.copy(ctx)
            inner.status, inner.status_why = g
            inner.exits, inner.exits_why = g
            inner.ignored = ""
            if not g[0]:
                inner.lost = g[1]
            sub = copy.copy(shell)
            if sub.program == "bash" and sub.errexit:
                sub.errexit, sub.why = False, "bash clears errexit inside `$( )`"
            self.body(Parser(toks).script(), sub, inner)

    def simple(self, cmd, shell, ctx, gate):
        n = 0
        while n < len(cmd.words) and ASSIGNMENT.match(cmd.words[n].text):
            n += 1
        argv = cmd.words[n:]
        subs = [s for w in cmd.words for s in w.subs]
        in_redirs, fed = [], None
        for op, target in cmd.redirs:
            in_redirs.extend(target.subs)
            if op.heredoc is not None:
                fed = op.heredoc
                if not fed.quoted:
                    in_redirs.extend(body_substitutions(fed))
        self.substitutions(in_redirs, shell, ctx, None)
        self.substitutions(subs, shell, ctx, None if argv else gate)
        if not argv or argv[0].arithmetic:
            return ""
        return self.resolved([w.value for w in argv], cmd, shell, ctx, gate, fed)

    def resolved(self, words, cmd, shell, ctx, gate, fed):
        """Past the prefix words to the command that runs, and what running it does to the shell."""
        text, replaced = short(" ".join(w.text for w in cmd.words)), False
        while words:
            name = words[0]
            if name == "command" and words[1:2] and words[1] in ("-v", "-V"):
                break
            if name in PREFIXES:
                rest = skip_prefix(name, words[1:])
                if name == "exec":
                    if not rest:
                        break
                    replaced = True
                    if not ctx.lost:
                        gate = (ctx.exits, ctx.exits_why)  # the command's status is the shell's own
                words = rest
            elif name in SHELLS:
                self.inner_shell(name, words[1:], text, cmd.line, shell, ctx, gate, fed)
                words = []
            else:
                break
        if words:
            self.emit(cmd.line, words, text, shell, ctx, gate)
            if words[0] == "set":
                self.set_options(words[1:], shell, ctx)
            elif words[0] == "exit" and ctx.reach == "always":
                return "it comes after `%s`, which ends the script" % text
        if replaced and ctx.reach == "always":
            return "it comes after `%s`, which replaces the shell" % text
        return ""

    def inner_shell(self, name, words, text, line, shell, ctx, gate, fed):
        """`bash script`, `bash -n script`, `bash -c 'string'` and `bash <<EOF`: the script, string or heredoc body is
        what runs, in a shell of its own with the options given here."""
        nested, string, rest = new_shell(name, words, "`%s`" % short(" ".join([name] + words[:2])))
        inner = copy.copy(ctx)
        inner.status, inner.status_why = gate
        inner.exits, inner.exits_why = gate
        inner.ignored = ""
        if string:
            Script.read(self, rest[0] if rest else "", nested, inner, line)
        elif rest and rest[0] != "-s":
            outer = copy.copy(shell)
            outer.noexec = shell.noexec or (nested.noexec and "`%s` only parses it (-n)" % text)
            self.emit(line, rest, text, outer, ctx, gate)
        elif fed is not None:
            Script.read(self, fed.body, nested, inner, fed.line)
        else:
            self.emit(line, [name] + words, text, shell, ctx, gate)

    def set_options(self, words, shell, ctx):
        """`set` changes the shell from here on. In a branch that may not run, only a change that weakens the step
        is taken: the options may be either way after it."""
        if ctx.reach == "never":
            return
        found, _, _ = option_words(words, False)
        sure, said = ctx.reach == "always", "`set %s`" % " ".join(words)
        if found["errexit"] is not None and (sure or not found["errexit"]):
            shell.errexit, shell.why = found["errexit"], "%s switches errexit off" % said
        if found["pipefail"] is not None and (sure or not found["pipefail"]):
            shell.pipefail, shell.pipefail_why = found["pipefail"], "%s switches pipefail off" % said
        if found["noexec"] and sure:
            shell.noexec = "it comes after %s: the shell only parses from there on" % said

    def emit(self, line, words, text, shell, ctx, gate):
        runs, why = ctx.reach, [ctx.reach_why] if ctx.reach != "always" and ctx.reach_why else []
        if shell.noexec and runs != "never":
            runs, why = "never", [shell.noexec]
        gates = gate[0] and runs != "never"
        if not gate[0] and gate[1] and runs != "never":
            why.append(gate[1])
        self.commands.append({"line": line, "command": words[0], "words": words, "text": text, "runs": runs,
                              "gates": gates, "why": why})


def kept(ctx):
    """The context as if its status were read: whether a command is reached does not hang on that."""
    c = copy.copy(ctx)
    c.lost = ""
    return c


def branch(ctx, why):
    """The context of commands that may not run."""
    c = copy.copy(ctx)
    if c.reach == "always":
        c.reach, c.reach_why = "conditional", why
    return c


def condition(ctx, why):
    """The context of a condition: errexit does not act on it and its status goes nowhere."""
    c = copy.copy(ctx)
    c.ignored, c.status, c.status_why = c.ignored or why, False, why
    return c


def certain_failure(pipe):
    """What follows `||`: 'exit' when it leaves the shell with a failure (`exit N`, N not 0; a bare `exit` or
    `exit $?`, which leave with the failed command's status; a `{ }` group ending in `exit N`), 'status' when it only
    fails (`false`; a group ending in `false`; a `( )` subshell ending in either), None when it can succeed."""
    if pipe.negated or len(pipe.cmds) != 1:
        return None
    return failure_of(pipe.cmds[0], first=True)


def failure_of(cmd, first):
    if cmd.kind == "simple":
        words = [w.value for w in cmd.words]
        if words == ["false"]:
            return "status"
        if words[:1] == ["exit"] and len(words) <= 2:
            code = words[1] if len(words) == 2 else "$?"
            if (code == "$?" and first) or (code.isdigit() and int(code) != 0):
                return "exit"
        return None
    if cmd.kind in ("group", "subshell") and cmd.body:
        node, background = cmd.body[-1]
        if background or len(node.elems) != 1 or node.elems[0].negated or len(node.elems[0].cmds) != 1:
            return None
        kind = failure_of(node.elems[0].cmds[0], first=first and len(cmd.body) == 1)
        return "status" if kind and cmd.kind == "subshell" else kind
    return None


def literal(value, word):
    """Whether an `if:` or `continue-on-error:` value is the literal true or false: the YAML boolean, the word, or the
    word alone inside `${{ }}`."""
    if isinstance(value, bool):
        return value == (word == "true")
    text = str(value).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.S)
    return (m.group(1) if m else text).strip() == word


def shell_of(step, job, doc):
    """The command line the runner starts for a step and how the step came by it, or '' and why it is not read."""
    value = None
    for level in (step, (job.get("defaults") or {}).get("run") or {}, (doc.get("defaults") or {}).get("run") or {}):
        if level.get("shell") is not None:
            value = str(level["shell"]).strip()
            break
    if value is None:
        if "windows" in json.dumps(job.get("runs-on", "")).lower():
            return "", "a Windows runner's default shell is pwsh"
        template, said = SHELL_TEMPLATES[""], "the default shell (`%s`)" % SHELL_TEMPLATES[""]
    else:
        template = SHELL_TEMPLATES.get(value, value)
        said = "`shell: %s`" % value
    if "${{" in template:
        return "", "its shell is an expression: %s" % value
    words = template.split()
    if not words or words[0].rsplit("/", 1)[-1] not in SHELLS or "{0}" not in words:
        return "", "its shell is not bash or sh: %s" % value
    return template, said


def conditions(holder, what, commands):
    """Apply a job's or a step's `if:` and `continue-on-error:` to commands. -> the conditions it runs under."""
    when = []
    cond = holder.get("if")
    if cond is not None:
        if literal(cond, "false"):
            for cmd in commands:
                cmd["runs"], cmd["gates"], cmd["why"] = "never", False, ["its %s has `if: %s`" % (what, cond)]
        elif not literal(cond, "true"):
            when.append(str(cond).strip())
    carry_on = holder.get("continue-on-error")
    if carry_on is not None and not literal(carry_on, "false"):
        for cmd in commands:
            if cmd["gates"]:
                cmd["gates"] = False
                cmd["why"].append("its %s has `continue-on-error: %s`" % (what, str(carry_on).strip()))
    return when


def read_step(step, job, doc):
    out = {"name": str(step.get("name", "")), "read": True, "when": [], "commands": []}
    if "uses" in step:
        out["uses"] = str(step["uses"])
    if "run" not in step:
        return out
    template, said = shell_of(step, job, doc)
    unread = "" if template else said
    if template:
        out["shell"] = template
        words = template.split()
        shell, _, _ = new_shell(words[0].rsplit("/", 1)[-1], words[1:], said)
        ctx = NS(reach="always", reach_why="", ignored="", status=True, status_why="", exits=True, exits_why="", lost="")
        script = Script()
        try:
            script.read(str(step["run"]), shell, ctx)
            out["commands"] = script.commands
        except Unread as e:
            unread = str(e)
    if unread:
        out["read"], out["unread"] = False, unread
    return out


def read(doc, path=""):
    """The report of a parsed workflow: {workflow, jobs: [{id, name, when, uses?, steps: [{index, name, read, unread?,
    shell?, uses?, when, commands: [{line, command, words, text, runs, gates, why}]}]}]}."""
    jobs = []
    for job_id, job in ((doc or {}).get("jobs") or {}).items():
        job = job or {}
        steps = []
        for index, step in enumerate(job.get("steps") or [], 1):
            out = dict(index=index, **read_step(step or {}, job, doc))
            out["when"] = conditions(step or {}, "step", out["commands"])
            steps.append(out)
        entry = {"id": str(job_id), "name": str(job.get("name", "")), "steps": steps}
        if "uses" in job:
            entry["uses"] = str(job["uses"])
        entry["when"] = conditions(job, "job", [c for s in steps for c in s["commands"]])
        jobs.append(entry)
    return {"workflow": path, "jobs": jobs}


def read_file(path):
    with open(path, encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    if not isinstance(doc, dict) or not isinstance(doc.get("jobs"), dict):
        raise ValueError("%s: no `jobs:` mapping, so it is no workflow" % path)
    return read(doc, path)


def matches(cmd, want):
    """Whether a reported command is the wanted one: its command word (a path may be longer on the left), then every
    further wanted word among its arguments."""
    word = cmd["command"][2:] if cmd["command"].startswith("./") else cmd["command"]
    return (word == want[0] or word.endswith("/" + want[0])) and all(w in cmd["words"][1:] for w in want[1:])


def required(reports, want, conditional=False):
    """-> (met, lines): where the wanted command runs and gates, or every place it is written and why it falls short."""
    good, short_of = [], []
    for report in reports:
        for job in report["jobs"]:
            for step in job["steps"]:
                where = "%s job %s step %d" % (report["workflow"], job["id"], step["index"])
                for cmd in step["commands"]:
                    if not matches(cmd, want):
                        continue
                    ok = cmd["gates"] and (cmd["runs"] == "always" or (conditional and cmd["runs"] == "conditional"))
                    line = "%s line %d: `%s`" % (where, cmd["line"], cmd["text"])
                    if ok:
                        good.append(line)
                    else:
                        short_of.append(line + ": " + ("; ".join(cmd["why"]) or "runs %s" % cmd["runs"]))
    return bool(good), good or short_of


def render(report):
    lines = [report["workflow"]]
    for job in report["jobs"]:
        head = "  job %s" % job["id"]
        if "uses" in job:
            head += "  uses %s" % job["uses"]
        lines.append(head + "".join("  [if: %s]" % w for w in job["when"]))
        for step in job["steps"]:
            head = "    step %d" % step["index"] + ("  %s" % step["name"] if step["name"] else "")
            if "uses" in step:
                head += "  uses %s" % step["uses"]
            lines.append(head + "".join("  [if: %s]" % w for w in step["when"]))
            if not step["read"]:
                lines.append("      unread: %s" % step["unread"])
            for cmd in step["commands"]:
                verdict = "%-11s %-5s" % (cmd["runs"], "gates" if cmd["gates"] else "-")
                lines.append("      %s  %s%s" % (verdict, cmd["text"], "".join("\n%26s%s" % ("", w) for w in cmd["why"])))
    return "\n".join(lines)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("workflows", nargs="+", metavar="WORKFLOW")
    ap.add_argument("--json", action="store_true", help="the report as JSON")
    ap.add_argument("--require", action="append", default=[], metavar="'CMD [ARG...]'",
                    help="a command that must run always and gate; may be given more than once")
    ap.add_argument("--conditional", action="store_true", help="a required command may run conditionally")
    args = ap.parse_args(argv)
    try:
        reports = [read_file(path) for path in args.workflows]
    except (OSError, ValueError, yaml.YAMLError) as e:
        print("ci-steps: %s" % e, file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(reports, indent=2))
    elif not args.require:
        print("\n".join(render(r) for r in reports))
    failed = 0
    for text in args.require:
        want = shlex.split(text)
        if not want:
            print("ci-steps: an empty --require", file=sys.stderr)
            return 2
        met, lines = required(reports, want, args.conditional)
        out = sys.stderr if args.json else sys.stdout
        if met:
            print("ok   `%s` runs and gates: %s" % (text, lines[0]), file=out)
        else:
            failed = 1
            print("FAIL `%s` %s" % (text, "is written and does not hold:" if lines else "is a command of no step"), file=out)
            for line in lines:
                print("       " + line, file=out)
    return failed


if __name__ == "__main__":
    sys.exit(main())
