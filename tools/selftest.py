import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import luaparse as L

bad = [
 ('bare method ref',   r'local x = a and a:Foo and a:Foo()'),
 ('missing end',       r'function f() if x then return 1 end'),
 ('assign to call',    r'f() = 3'),
 ('bad table sep',     r'local t = {1 2}'),
 ('dangling and',      r'local x = 1 and'),
 ('unfinished string', r'local s = "abc'),
 ('stray paren',       r'local x = (1 + 2'),
 ('return mid-block',  r'do return 1 print(2) end'),
 ('bad for',           r'for i 1,10 do end'),
 ('keyword as name',   r'local end = 1'),
 ('method no args',    r'a:b'),
 ('double op',         r'local x = 1 + * 2'),
 ('unclosed long str', r'local s = [[abc'),
 ('bad escape',        r'local s = "a\q"'),
 ('malformed number',  r'local x = 12ab'),
 ('else after else',   r'if x then else else end'),
 ('extra end',         r'do end end'),
 ('break mid-block',   r'while 1 do break print(1) end'),
]
good = [
 ('method call',       r'a:b()'),
 ('string call',       r'print"hi"'),
 ('table call',        r'f{1,2}'),
 ('semicolon table',   r'local t = {1;2;a=3,[4]=5,}'),
 ('concat right assoc',r'local x = a..b..c'),
 ('pow right assoc',   r'local x = 2^3^4'),
 ('unary',             r'local x = -#t'),
 ('varargs',           r'local function f(a,...) return ... end'),
 ('nested long',       r'local s = [==[ ]] ]==]'),
 ('long comment',      '--[[ x\ny ]] print(1)'),
 ('chain suffixes',    r'a.b.c[1]:d(1)(2){3}"4"'),
 ('repeat scope',      r'repeat local x = 1 until x'),
 ('numeric forms',     r'local a,b,c,d = 0xFF, 1e5, .5, 3.'),
 ('empty chunk',       r''),
 ('semicolons',        r';;; print(1) ;;;'),
 ('multi assign',      r'a.b, c[1], d = 1, 2, 3'),
 ('nested funcs',      r'local t = {f = function(self) return self.x end}'),
 ('generic for',       r'for k,v in pairs(t) do end'),
 ('method def',        r'function A.B:C(x) return x end'),
 ('not/and/or',        r'local x = not a and b or c'),
 ('paren call',        r'local x = ("%s"):format(1)'),
 ('escape digits',     r'local s = "\65\066\9"'),
]
fails = 0
for n, s in bad:
    try:
        L.parse_source(s)
        print('MISS  accepted bad  : %-20s %r' % (n, s)); fails += 1
    except L.LuaSyntaxError as e:
        print('ok    rejected      : %-20s -> %s' % (n, e))
for n, s in good:
    try:
        L.parse_source(s)
        print('ok    accepted      : %s' % n)
    except L.LuaSyntaxError as e:
        print('MISS  rejected good : %-20s -> %s' % (n, e)); fails += 1
print('---')

# ---------------------------------------------------------------------------
# Regression: the real bug this parser was written for.
#
# MapPins.lua used `WorldMapFrame:GetMapID` as a VALUE, to test whether the
# method exists. `a:b` is not an expression in Lua -- it is only legal as
# `a:b(args)`. The file failed to compile and the addon silently lost its map
# pins. Both of the earlier byte-counting checkers called the file fine.
#
# This checks the live file both ways: as shipped it must parse, and with the
# one character put back it must fail on that exact line and column.
# Nothing is written to disk -- the mutation is in memory only.
# ---------------------------------------------------------------------------

ADDON = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAPPINS = os.path.join(ADDON, 'MapPins.lua')
FIXED = 'and WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()'
BROKEN = 'and WorldMapFrame:GetMapID and WorldMapFrame:GetMapID()'

if not os.path.exists(MAPPINS):
    print('SKIP  MapPins.lua regression (file not found at %s)' % MAPPINS)
else:
    src = open(MAPPINS, 'rb').read().decode('utf-8')
    lines = src.split('\n')

    hits = [i for i, l in enumerate(lines) if FIXED in l]
    if len(hits) != 1:
        print('MISS  regression setup: expected 1 fixed line, found %d' % len(hits))
        fails += 1
    else:
        lineno = hits[0] + 1

        # 1. the file as it stands must parse clean
        try:
            L.parse_source(src)
            print('ok    MapPins.lua as shipped parses clean (fix at line %d)' % lineno)
        except L.LuaSyntaxError as e:
            print('MISS  MapPins.lua should parse but failed -> %s' % e); fails += 1

        # 2. put the colon back in memory; must fail at that line and column
        broken_line = lines[hits[0]].replace(FIXED, BROKEN)
        want_col = broken_line.index(':GetMapID and') + len(':GetMapID ') + 1
        mutated = list(lines)
        mutated[hits[0]] = broken_line
        try:
            L.parse_source('\n'.join(mutated))
            print('MISS  broken method-reference accepted at line %d' % lineno)
            fails += 1
        except L.LuaSyntaxError as e:
            if e.line == lineno and e.col == want_col:
                print('ok    broken form caught at %d:%d -> %s'
                      % (e.line, e.col, e.msg))
            else:
                print('MISS  broken form caught at %d:%d, expected %d:%d'
                      % (e.line, e.col, lineno, want_col))
                fails += 1

print('---')
print('FAILURES: %d' % fails)
sys.exit(1 if fails else 0)
