#!/usr/bin/env python3
"""
luaparse.py -- a real Lua 5.1 syntax checker.

Lexer + recursive-descent parser over the Lua 5.1 reference grammar.
Reports the first syntax error with precise line and column.

Usage:
    python luaparse.py FILE [FILE...]
    python luaparse.py DIR            (parses *.lua in DIR)

Exit status 0 if everything parses, 1 otherwise.
"""

import os
import sys

# ---------------------------------------------------------------- lexer

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}

# longest first so that maximal munch works
SYMBOLS = [
    "...", "..", ".",
    "==", "~=", "<=", ">=", "<", ">", "=",
    "+", "-", "*", "/", "%", "^", "#",
    "(", ")", "{", "}", "[", "]",
    ";", ":", ",",
]

DIGITS = "0123456789"
HEXDIGITS = "0123456789abcdefABCDEF"


class LuaSyntaxError(Exception):
    def __init__(self, msg, line, col):
        Exception.__init__(self, msg)
        self.msg = msg
        self.line = line
        self.col = col

    def __str__(self):
        return "line %d, col %d: %s" % (self.line, self.col, self.msg)


class Token(object):
    __slots__ = ("type", "value", "line", "col")

    def __init__(self, type_, value, line, col):
        self.type = type_          # 'name','number','string','kw','sym','eof'
        self.value = value
        self.line = line
        self.col = col

    def __repr__(self):
        return "<%s %r @%d:%d>" % (self.type, self.value, self.line, self.col)


def _is_name_start(c):
    return c.isalpha() or c == "_"


def _is_name_char(c):
    return c.isalnum() or c == "_"


class Lexer(object):
    def __init__(self, src):
        self.src = src
        self.n = len(src)
        self.i = 0
        self.line = 1
        self.bol = 0            # index of beginning of current line

    def col(self, i=None):
        if i is None:
            i = self.i
        return i - self.bol + 1

    def error(self, msg, i=None):
        raise LuaSyntaxError(msg, self.line, self.col(i))

    def _newline(self):
        """Consume a newline sequence (\\n, \\r, \\r\\n, \\n\\r) at self.i."""
        c = self.src[self.i]
        self.i += 1
        if self.i < self.n and self.src[self.i] in "\r\n" and self.src[self.i] != c:
            self.i += 1
        self.line += 1
        self.bol = self.i

    # --- long bracket [[ ]] / [=[ ]=] -------------------------------
    def _long_bracket_level(self, i):
        """If src[i] starts a long bracket opener, return (level, index_after).
        Otherwise return None."""
        if i >= self.n or self.src[i] != "[":
            return None
        j = i + 1
        level = 0
        while j < self.n and self.src[j] == "=":
            level += 1
            j += 1
        if j < self.n and self.src[j] == "[":
            return (level, j + 1)
        return None

    def _read_long_string(self, level, start_i, what):
        """Read a long string/comment body starting at start_i (just past the
        opening bracket). Returns the raw body text."""
        i = start_i
        # first newline immediately after opener is skipped
        if i < self.n and self.src[i] in "\r\n":
            self.i = i
            self._newline()
            i = self.i
        closer = "]" + ("=" * level) + "]"
        while True:
            if i >= self.n:
                self.i = i
                self.error("unfinished long %s" % what)
            c = self.src[i]
            if c == "]" and self.src.startswith(closer, i):
                body = self.src[start_i:i]
                self.i = i + len(closer)
                return body
            if c in "\r\n":
                self.i = i
                self._newline()
                i = self.i
            else:
                i += 1

    # --- short string -----------------------------------------------
    def _read_short_string(self, quote):
        start_line, start_col = self.line, self.col()
        self.i += 1
        out = []
        while True:
            if self.i >= self.n:
                raise LuaSyntaxError("unfinished string", start_line, start_col)
            c = self.src[self.i]
            if c == quote:
                self.i += 1
                return "".join(out)
            if c in "\r\n":
                raise LuaSyntaxError("unfinished string (newline in string)",
                                     self.line, self.col())
            if c == "\\":
                self.i += 1
                if self.i >= self.n:
                    self.error("unfinished string escape")
                e = self.src[self.i]
                if e in "\r\n":
                    self._newline()
                    out.append("\n")
                    continue
                if e in "abfnrtv\\\"'":
                    out.append(e)
                    self.i += 1
                    continue
                if e in DIGITS:
                    num = ""
                    k = 0
                    while k < 3 and self.i < self.n and self.src[self.i] in DIGITS:
                        num += self.src[self.i]
                        self.i += 1
                        k += 1
                    if int(num) > 255:
                        self.error("decimal escape too large")
                    out.append(chr(int(num)))
                    continue
                self.error("invalid escape sequence '\\%s'" % e)
            else:
                out.append(c)
                self.i += 1

    # --- number -------------------------------------------------------
    def _read_number(self):
        start = self.i
        src, n = self.src, self.n
        if src[self.i] == "0" and self.i + 1 < n and src[self.i + 1] in "xX":
            self.i += 2
            d = 0
            while self.i < n and src[self.i] in HEXDIGITS:
                self.i += 1
                d += 1
            if d == 0:
                self.error("malformed number near '%s'" % src[start:self.i])
        else:
            seen_digit = False
            while self.i < n and src[self.i] in DIGITS:
                self.i += 1
                seen_digit = True
            if self.i < n and src[self.i] == ".":
                self.i += 1
                while self.i < n and src[self.i] in DIGITS:
                    self.i += 1
                    seen_digit = True
            if not seen_digit:
                self.error("malformed number")
            if self.i < n and src[self.i] in "eE":
                save = self.i
                self.i += 1
                if self.i < n and src[self.i] in "+-":
                    self.i += 1
                if self.i < n and src[self.i] in DIGITS:
                    while self.i < n and src[self.i] in DIGITS:
                        self.i += 1
                else:
                    self.i = save
        # a name character immediately after a number is malformed
        if self.i < n and _is_name_char(src[self.i]):
            j = self.i
            while j < n and _is_name_char(src[j]):
                j += 1
            self.error("malformed number near '%s'" % src[start:j])
        return src[start:self.i]

    # --- main ----------------------------------------------------------
    def tokens(self):
        src, n = self.src, self.n
        first = True
        while True:
            # skip whitespace and comments
            while self.i < n:
                c = src[self.i]
                if c in "\r\n":
                    self._newline()
                elif c in " \t\v\f":
                    self.i += 1
                elif c == "-" and src.startswith("--", self.i):
                    self.i += 2
                    lb = self._long_bracket_level(self.i)
                    if lb is not None:
                        level, after = lb
                        self._read_long_string(level, after, "comment")
                    else:
                        while self.i < n and src[self.i] not in "\r\n":
                            self.i += 1
                elif first and self.i == 0 and c == "#":
                    # shebang line
                    while self.i < n and src[self.i] not in "\r\n":
                        self.i += 1
                else:
                    break
            first = False
            if self.i >= n:
                yield Token("eof", "<eof>", self.line, self.col())
                return

            line, col = self.line, self.col()
            c = src[self.i]

            if _is_name_start(c):
                j = self.i
                while j < n and _is_name_char(src[j]):
                    j += 1
                word = src[self.i:j]
                self.i = j
                if word in KEYWORDS:
                    yield Token("kw", word, line, col)
                else:
                    yield Token("name", word, line, col)
                continue

            if c in DIGITS or (c == "." and self.i + 1 < n and src[self.i + 1] in DIGITS):
                val = self._read_number()
                yield Token("number", val, line, col)
                continue

            if c in "\"'":
                val = self._read_short_string(c)
                yield Token("string", val, line, col)
                continue

            if c == "[":
                lb = self._long_bracket_level(self.i)
                if lb is not None:
                    level, after = lb
                    self.i = after
                    body = self._read_long_string(level, after, "string")
                    yield Token("string", body, line, col)
                    continue
                # otherwise fall through to symbols

            for sym in SYMBOLS:
                if src.startswith(sym, self.i):
                    self.i += len(sym)
                    yield Token("sym", sym, line, col)
                    break
            else:
                self.error("unexpected symbol near '%s'" % c)


# ---------------------------------------------------------------- parser

# binary operator precedence: op -> (left, right)
BINPRI = {
    "or": (1, 1),
    "and": (2, 2),
    "<": (3, 3), ">": (3, 3), "<=": (3, 3), ">=": (3, 3),
    "~=": (3, 3), "==": (3, 3),
    "..": (9, 8),          # right associative
    "+": (10, 10), "-": (10, 10),
    "*": (11, 11), "/": (11, 11), "%": (11, 11),
    "^": (14, 13),         # right associative
}
UNARY_PRI = 12

BLOCK_ENDERS = {"end", "else", "elseif", "until"}


def _describe(tok):
    if tok.type == "eof":
        return "<eof>"
    if tok.type == "string":
        return "a string"
    return "'%s'" % tok.value


class Parser(object):
    def __init__(self, src, name="<input>"):
        self.name = name
        self.toks = list(Lexer(src).tokens())
        self.p = 0

    # --- token helpers ------------------------------------------------
    @property
    def tok(self):
        return self.toks[self.p]

    def next(self):
        t = self.toks[self.p]
        if t.type != "eof":
            self.p += 1
        return t

    def check(self, type_, value=None):
        t = self.tok
        if t.type != type_:
            return False
        return value is None or t.value == value

    def accept(self, type_, value=None):
        if self.check(type_, value):
            return self.next()
        return None

    def error(self, msg, tok=None):
        t = tok or self.tok
        raise LuaSyntaxError(msg, t.line, t.col)

    def expect(self, type_, value, what=None):
        if self.check(type_, value):
            return self.next()
        self.error("'%s' expected, got %s%s" %
                   (value, _describe(self.tok), what or ""))

    def expect_match(self, value, opening, line):
        """Expect a closing token, mentioning where the construct opened."""
        if self.check("kw", value) or self.check("sym", value):
            return self.next()
        if line == self.tok.line:
            self.error("'%s' expected, got %s" % (value, _describe(self.tok)))
        self.error("'%s' expected (to close '%s' at line %d), got %s"
                   % (value, opening, line, _describe(self.tok)))

    def expect_name(self):
        if self.check("name"):
            return self.next()
        self.error("<name> expected, got %s" % _describe(self.tok))

    # --- grammar -------------------------------------------------------
    def parse_chunk(self):
        self.block()
        if not self.check("eof"):
            self.error("'<eof>' expected, got %s" % _describe(self.tok))

    def block_follow(self):
        t = self.tok
        if t.type == "eof":
            return True
        return t.type == "kw" and t.value in BLOCK_ENDERS

    def block(self):
        while not self.block_follow():
            if self.check("kw", "return") or self.check("kw", "break"):
                self.laststat()
                while self.accept("sym", ";"):
                    pass
                return
            self.statement()
            while self.accept("sym", ";"):
                pass

    def laststat(self):
        if self.accept("kw", "break"):
            return
        self.expect("kw", "return")
        if not self.block_follow() and not self.check("sym", ";"):
            self.explist()

    def statement(self):
        t = self.tok
        if t.type == "kw":
            v = t.value
            if v == "if":
                return self.if_stat()
            if v == "while":
                return self.while_stat()
            if v == "do":
                line = t.line
                self.next()
                self.block()
                self.expect_match("end", "do", line)
                return
            if v == "for":
                return self.for_stat()
            if v == "repeat":
                return self.repeat_stat()
            if v == "function":
                return self.func_stat()
            if v == "local":
                return self.local_stat()
            self.error("unexpected symbol near '%s'" % v)
        if t.type == "sym" and t.value == ";":
            self.next()
            return
        return self.expr_stat()

    def if_stat(self):
        line = self.tok.line
        self.expect("kw", "if")
        self.expr()
        self.expect("kw", "then")
        self.block()
        while self.check("kw", "elseif"):
            self.next()
            self.expr()
            self.expect("kw", "then")
            self.block()
        if self.accept("kw", "else"):
            self.block()
        self.expect_match("end", "if", line)

    def while_stat(self):
        line = self.tok.line
        self.expect("kw", "while")
        self.expr()
        self.expect("kw", "do")
        self.block()
        self.expect_match("end", "while", line)

    def repeat_stat(self):
        line = self.tok.line
        self.expect("kw", "repeat")
        self.block()
        self.expect_match("until", "repeat", line)
        self.expr()

    def for_stat(self):
        line = self.tok.line
        self.expect("kw", "for")
        self.expect_name()
        if self.accept("sym", "="):
            self.expr()
            self.expect("sym", ",")
            self.expr()
            if self.accept("sym", ","):
                self.expr()
        elif self.check("sym", ",") or self.check("kw", "in"):
            while self.accept("sym", ","):
                self.expect_name()
            self.expect("kw", "in")
            self.explist()
        else:
            self.error("'=' or 'in' expected, got %s" % _describe(self.tok))
        self.expect("kw", "do")
        self.block()
        self.expect_match("end", "for", line)

    def func_stat(self):
        line = self.tok.line
        self.expect("kw", "function")
        # funcname: Name {'.' Name} [':' Name]
        self.expect_name()
        while self.accept("sym", "."):
            self.expect_name()
        self.accept("sym", ":") and self.expect_name()
        self.funcbody(line)

    def local_stat(self):
        self.expect("kw", "local")
        if self.accept("kw", "function"):
            line = self.toks[self.p - 1].line
            self.expect_name()
            self.funcbody(line)
            return
        self.expect_name()
        while self.accept("sym", ","):
            self.expect_name()
        if self.accept("sym", "="):
            self.explist()

    def funcbody(self, line):
        self.expect("sym", "(")
        if not self.check("sym", ")"):
            while True:
                if self.accept("sym", "..."):
                    break
                self.expect_name()
                if not self.accept("sym", ","):
                    break
        self.expect("sym", ")")
        self.block()
        self.expect_match("end", "function", line)

    def expr_stat(self):
        start = self.tok
        kind = self.suffixedexp()
        if self.check("sym", "=") or self.check("sym", ","):
            if kind != "var":
                self.error("syntax error near %s (cannot assign to this)"
                           % _describe(self.tok))
            while self.accept("sym", ","):
                k = self.suffixedexp()
                if k != "var":
                    self.error("syntax error near %s (cannot assign to this)"
                               % _describe(self.tok))
            self.expect("sym", "=")
            self.explist()
            return
        if kind != "call":
            self.error("syntax error near %s" % _describe(self.tok), start
                       if self.tok.type == "eof" else None)

    def explist(self):
        self.expr()
        while self.accept("sym", ","):
            self.expr()

    # primaryexp: Name | '(' expr ')'
    def primaryexp(self):
        t = self.tok
        if t.type == "name":
            self.next()
            return "var"
        if t.type == "sym" and t.value == "(":
            line = t.line
            self.next()
            self.expr()
            self.expect_match(")", "(", line)
            return "exp"
        self.error("unexpected symbol near %s" % _describe(t))

    # suffixedexp: primaryexp { '.' Name | '[' exp ']' | ':' Name args | args }
    def suffixedexp(self):
        kind = self.primaryexp()
        while True:
            t = self.tok
            if t.type == "sym":
                v = t.value
                if v == ".":
                    self.next()
                    self.expect_name()
                    kind = "var"
                    continue
                if v == "[":
                    line = t.line
                    self.next()
                    self.expr()
                    self.expect_match("]", "[", line)
                    kind = "var"
                    continue
                if v == ":":
                    self.next()
                    self.expect_name()
                    self.args()
                    kind = "call"
                    continue
                if v == "(" or v == "{":
                    self.args()
                    kind = "call"
                    continue
            if t.type == "string":
                self.args()
                kind = "call"
                continue
            return kind

    def args(self):
        t = self.tok
        if t.type == "string":
            self.next()
            return
        if t.type == "sym" and t.value == "{":
            self.tableconstructor()
            return
        if t.type == "sym" and t.value == "(":
            line = t.line
            self.next()
            if not self.check("sym", ")"):
                self.explist()
            self.expect_match(")", "(", line)
            return
        self.error("function arguments expected, got %s" % _describe(t))

    def tableconstructor(self):
        line = self.tok.line
        self.expect("sym", "{")
        while not self.check("sym", "}"):
            if self.check("sym", "["):
                blin = self.tok.line
                self.next()
                self.expr()
                self.expect_match("]", "[", blin)
                self.expect("sym", "=")
                self.expr()
            elif self.check("name") and self.toks[self.p + 1].type == "sym" \
                    and self.toks[self.p + 1].value == "=":
                self.next()
                self.next()
                self.expr()
            else:
                self.expr()
            if self.accept("sym", ",") or self.accept("sym", ";"):
                continue
            break
        self.expect_match("}", "{", line)

    def simpleexp(self):
        t = self.tok
        if t.type in ("number", "string"):
            self.next()
            return
        if t.type == "kw" and t.value in ("nil", "true", "false"):
            self.next()
            return
        if t.type == "sym" and t.value == "...":
            self.next()
            return
        if t.type == "sym" and t.value == "{":
            self.tableconstructor()
            return
        if t.type == "kw" and t.value == "function":
            line = t.line
            self.next()
            self.funcbody(line)
            return
        self.suffixedexp()

    def expr(self, limit=0):
        t = self.tok
        if (t.type == "kw" and t.value == "not") or \
           (t.type == "sym" and t.value in ("-", "#")):
            self.next()
            self.expr(UNARY_PRI)
        else:
            self.simpleexp()
        while True:
            t = self.tok
            if t.type == "sym" or t.type == "kw":
                pri = BINPRI.get(t.value)
                if pri and pri[0] > limit:
                    self.next()
                    self.expr(pri[1])
                    continue
            return


def parse_source(src, name="<input>"):
    """Parse source text. Raises LuaSyntaxError on failure."""
    if src.startswith("﻿"):
        src = src[1:]
    Parser(src, name).parse_chunk()


def check_file(path):
    with open(path, "rb") as f:
        raw = f.read()
    try:
        src = raw.decode("utf-8")
    except UnicodeDecodeError:
        src = raw.decode("latin-1")
    try:
        parse_source(src, path)
    except LuaSyntaxError as e:
        return e
    return None


def main(argv):
    targets = []
    for a in argv:
        if os.path.isdir(a):
            for f in sorted(os.listdir(a)):
                if f.lower().endswith(".lua"):
                    targets.append(os.path.join(a, f))
        else:
            targets.append(a)
    if not targets:
        print(__doc__)
        return 2
    bad = 0
    for t in targets:
        err = check_file(t)
        if err is None:
            print("OK    %s" % t)
        else:
            bad += 1
            print("FAIL  %s:%d:%d: %s" % (t, err.line, err.col, err.msg))
    print("---\n%d file(s), %d error(s)" % (len(targets), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
