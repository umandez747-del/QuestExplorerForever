# tools/ — development only

Nothing in this folder is part of the addon. It is not listed in
`QuestExplorerForever.toc`, so the game never reads it. Delete it at any time
without affecting Quest Explorer Forever. If you ever zip the addon for
distribution, leave this folder out.

## luaparse.py — Lua 5.1 syntax checker

A lexer plus recursive-descent parser over the real Lua 5.1 grammar. It answers
one question: *would the game's Lua compiler accept this file?* Python 3, no
dependencies.

Check every Lua file in the addon:

```powershell
python tools\luaparse.py .
```

Check one file:

```powershell
python tools\luaparse.py MapPins.lua
```

Output is `OK <file>` or `FAIL <file>:<line>:<col>: <message>`, one line each,
with a count at the end. Exit status is 0 when everything parses and 1 when
anything fails, so it drops straight into a pre-launch check or a git hook.

### Why this exists

On 2026-11-18 `MapPins.lua` silently failed to load. `/qef status` reported
`missing MapPins` while all thirty other files loaded fine. The cause was on
line 441:

```lua
and WorldMapFrame:GetMapID and WorldMapFrame:GetMapID()
--  ^ used as a value, which Lua's grammar does not allow
```

`a:b` is only legal as a call, `a:b(args)` — it is not an expression, so it
cannot be used to test whether a method exists. The fix was `:` to `.` on the
existence test. The call on the same line keeps its colon.

Brackets balanced. Block keywords balanced. Encoding, BOM and line endings all
clean. Every counting or balancing tool said the file was fine, because the file
*was* well-formed text — it simply was not valid Lua. Only a real parser sees
this class of bug, which is the whole reason this one is here.

### What it covers

Long strings and comments with `[=[` nesting levels; string- and table-call
sugar (`f"x"`, `f{1}`); `,` and `;` table separators; right-associative `..` and
`^` with correct precedence against everything else; `return`/`break` as
laststat only; assignment-target validity (`f() = 1` is rejected); numeric
literal forms including hex, exponents and leading/trailing dots; escape
sequence validity.

It is a *syntax* checker. It knows nothing about runtime behaviour, globals,
typos in API names, or scoping — a file can pass here and still misbehave in
game.

## selftest.py

Run it after any change to `luaparse.py`:

```powershell
python tools\selftest.py
```

18 malformed snippets that must be rejected and 22 valid ones that must be
accepted, including the exact `a:Foo and a:Foo()` shape above. Prints a line per
case and exits non-zero on any disagreement.
