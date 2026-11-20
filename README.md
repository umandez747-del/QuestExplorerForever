# Quest Explorer Forever

Shows what a quest actually involves before you accept it: what it asks for, what it rewards,
what the rest of the chain leads to, and whether it unlocks a dungeon quest. At quest givers,
in gossip and greeting lists, beside the quest log, and on Questie's map and minimap icons —
plus a dungeon run planner that marks each step of a run on your map in turn.

Called **QuestPreview** until 2.0.0; the rename brings your settings, learned rewards and
checklists with it, as *Saved variables* below describes.

- **Folder:** `_forever_\Interface\AddOns\QuestExplorerForever`
- **Commands:** `/qef`, `/questexplorer`, and `/qp` still answers
- **Client:** Forever, `## Interface: 16001`
- **Optional:** QuestieDB (strongly recommended), Questie

## Saved variables

The game names an addon's saved variables file after the addon, so renaming the folder gives
it a new, empty one and leaves the old `QuestPreview.lua` orphaned beside it. Copying that
file to `QuestExplorerForever.lua` is what carries the data across, and that has been done
for you — in `WTF\Account\<account>\SavedVariables`.

The .toc declares both `QuestExplorerForeverDB` and the old `QuestPreviewDB`, so the old
table is loaded and adopted whole the first time it is seen. Only ever when the new one is
untouched: merging two sets of settings would be guesswork about which is current. It is
cleared afterwards, so the old name is not written back out forever, and the addon says in
chat that it happened — a rename that quietly loses your settings and one that keeps them
look identical until you go looking.

## Why `_forever_` and not `_retail_`

Questie, QuestieDB and QuestieTrace are only installed under `_forever_`. `_retail_` has no
Questie at all, and retail's quest system has neither the chain structure nor the data this
addon reads. Forever reports Interface 16001 and shares retail's project ID, which is why
Questie detects it as `interfaceVersion >= 16000 and < 17000` rather than by project.

## Where the data comes from

This was the question worth settling before writing anything, because the obvious assumption
is wrong.

**Questie's quest database does not contain quest rewards.** Its quest records have 36 fields
covering names, levels, objectives, prerequisites, chain links, reputation and zones — and no
item-reward field at all. Chain structure is completely available statically; item rewards are
not.

So rewards are resolved in four tiers, best first. Every preview names its tier under
`/qef verbosity 3`.

| # | Source | Covers | Exact? |
|---|--------|--------|--------|
| 1 | The open quest giver frame (`GetQuestItemInfo`, `GetRewardXP`, `GetRewardMoney`) | the quest on screen | yes, including the choice/fixed split |
| 2 | Saved variables — anything tier 1 or 3 established before | quests you have been offered | yes |
| 3 | `C_QuestLog.RequestLoadQuestByID` + the quest-log reward APIs | **any quest id**, asked of the server | yes, when the server answers |
| 4 | QuestieDB's `Item.questRewards` relation, inverted at login, plus its quest XP table | ~2,500 of 5,893 quests | no — items only, no choice/fixed split |

Tier 3 is the one that makes chain lookahead work. `C_QuestLog.RequestLoadQuestByID` exists on
Forever and answers for arbitrary quest ids, not just quests in your log, so "this chain ends
with [item]" is usually the server's own answer rather than a guess. It is asynchronous; the
preview draws immediately with the best tier it has and redraws when the answer arrives.

Chain structure, levels, objectives, reputation rewards and dungeon detection all come from
**QuestieDB**, which is a separate addon from Questie and works without it:

- forward chain links by inverting `preQuestSingle`, `preQuestGroup`, `parentQuest` and
  `availableStartingWith`, plus the direct `nextQuestInChain`, `childQuests` and breadcrumb
  fields;
- base XP from `LibQuestieDB.Support.Get("QuestXP")`, scaled for your level with the same
  formula Questie uses;
- dungeons from `LibQuestieDB.Support.Get("ZoneDB").private.dungeons`, matched against each
  quest's `zoneOrSort`.

**Nothing is downloaded and no external data dump is used.** Both reverse indices are rebuilt
from the installed QuestieDB at every login, which takes well under a second and can never go
stale against a QuestieDB update. QuestieDB stores its data in TOC metadata, so the item pass
asks "does this item have a reward relation?" with a single metadata lookup per item and only
decodes the ~2,500 that do.

## Known gaps

These are real and worth knowing before you trust a preview:

- **Choice vs fixed is unknown at tier 4.** When only QuestieDB can answer, the block is
  labelled *Possible rewards* rather than *Choose one*, because the database records which
  items a quest can give but not how they are handed out. Running the sweep removes this for
  every quest the server answers for.
- **Money has no static source.** Without a live answer the money line is simply absent
  rather than shown as zero.
- **"Step 2 of about 4" is an estimate.** Chains are graphs, not lines — they branch and
  rejoin — so the position is depth from the chain root against the longest path through it.
- **Forever's own new quests** may be missing from a Classic-derived database, and tend to be
  the same ones the server declines to load reward data for. Those preview as name and level
  only.
- **Waypoints are not reliable on every map.** Forever's user-waypoint API is known to refuse
  some maps — ForeverDungeonJournal avoids it entirely for that reason. This addon uses it
  because it is the built-in one, guards with `CanSetUserWaypointOnMap`, and then reads the
  waypoint back to check it actually stuck. A refusal is reported in chat rather than leaving
  you looking at an empty map.
- **Status for very old quests** comes from the client's completed-quest list, merged with
  Questie's own record when Questie is loaded, because the client API has historically been
  unreliable for early Classic quests.
- **"Locked" is a best guess.** It checks the recorded prerequisites only; a quest gated by
  something the database does not record will read as available.
- **Secret values.** Forever can return quest ids and other values that addons may not read.
  Every id is checked before use, and an entry whose id is secret gets no preview rather than
  a wrong one.
- Reward **stats** are item level and slot/subtype, not a full stat block. Use panel mode, where
  hovering a reward line shows the real item tooltip.
- Items the client has never cached show QuestieDB's name and item level until the client
  loads them; the preview redraws itself when it does.
- **Turn-in NPCs** come from the database's `finishedBy`. A quest handed in to an object, or
  completed by using an item, has no NPC recorded, and the checklist says so rather than
  guessing. Where an NPC is recorded but has no spawn, you get the name without a place.

## Beside the quest log

The panel also appears next to an open quest log, for whichever quest is selected there,
and follows the selection as you click down the list.

It is **attached to the frame**, not floating beside it: flush against the edge, overlapping
by a pixel so the two borders land on each other as one line, with the hairline on the
joined side removed and an accent seam in its place. The result reads as a panel on the side
of the log rather than as a second window that happens to be nearby. Classic's parchment
frames are drawn inside a decorative border, so the attachment is trimmed by a per-frame
inset to meet the edge you can actually see; `/qef attach` turns the whole thing off and goes
back to floating, and dragging the panel detaches it either way.

**It minimises into a tab.** The button in the corner folds the panel away into a slim
`PREVIEW` tab on the outside edge of the frame, below the top corner so it reads as a tab
rather than as part of the frame's own border, carrying the same accent seam. Click the tab
and it opens back up.

Minimising is **sticky**, which is the whole point of minimising something: it stays folded
as you click down the quest log rather than springing open on every selection, and the tab
follows the selection and names whatever quest it is standing for. It survives a reload. A
panel with nothing to tuck against — one you have dragged into the middle of the screen —
has no edge for a tab, so there the button is an ordinary close. `/qef minimise` does the
same from the keyboard.

It leaves out the objectives, since the log is already showing those in full with their
progress counts, and shows the part the log does not: where the quest sits in its chain,
what it leads to, who you hand it back to, and whether it ends in a dungeon. It is always
the panel here, whatever the display mode is set to — there is nothing to hover in a quest
log — and it gets out of the way when a fight starts, coming back when the fight ends.

Which frame the log is depends on the build, so rather than betting on one this hooks every
selection function that exists (`QuestLog_SetSelection`, `QuestMapFrame_ShowQuestDetails`,
`C_QuestLog.SetSelectedQuest`) and backs them with a quarter-second poll while a log frame
is open — which costs four table lookups, and nothing at all when no log is open.

Three things that only show up against a real UI, and all three bite when a map addon is
involved:

- **It attaches to the window, not the panel.** `QuestMapFrame` is a pane *inside* the world
  map, so attaching to it puts the preview on top of the map it belongs to. The anchor walks
  up to the outermost frame below `UIParent` instead, which is the map window itself —
  whatever an addon has made of it.
- **Visible, not shown.** A pane inside a closed window still reports itself as shown, so
  closing the map used to leave the preview floating over the world. `IsVisible` is the
  test, everywhere.
- **Edges are measured in the interface's units.** A frame reports its edges in its own
  scale, and a map addon that rescales the map would otherwise have the panel deciding which
  side to sit on from the wrong numbers. A wide map can have room for the panel on neither
  side, in which case it takes the roomier one.

`/qef status` reports which hooks it found and what it is attached to right now. `/qef
questlog` turns the whole thing off, and `/qef attach` just the attachment.

## Pins on the world map

The checklist draws itself on the world map: a pin for every step you still owe on whatever
zone you are looking at, and for the objectives of the ones already in your log. The pin the
guide's marker is on wears a ring, so the map agrees with the strip about which step you are
walking to. Hovering one gives the addon's own preview tooltip rather than a name and a
dash, and clicking it moves the marker to that step.

**The quests you are carrying are pinned too.** The checklist draws what you planned;
the game puts a `?` over anything you can hand in whether you planned it or not. Until
those two met, a turn-in you had not put on a list showed Blizzard's mark and none of
ours — which reads as ours being broken rather than as ours being narrow. So every quest
in your log that is not on the checklist now gets the treatment it would have had on it:
the `?` pin where you hand it in, or its objective creatures while it is still in
progress, under the same forty-pin ceiling.

**The zone's own quests are pinned too**, not just your checklist: every quest in the zone
you are looking at that you could walk up and accept, faction-filtered and status-filtered,
drawn in the blue pin so a glance tells you which marks you chose and which the zone merely
has. The browser's index already knows every quest by zone, so this is a filter over data
that gets built either way; the cost is one spawn lookup per quest that passes, which is why
the answer is cached per map and thrown away on any quest event. A zone is capped at sixty
of them, past which a map stops being a map and becomes a wall of exclamation marks.
Anything already on the checklist is left to its own step pin rather than drawn twice.
`/qef pins available` turns both of those off and leaves the map to your own list.

**With Questie installed they stay off.** That is what `auto`, the default, means. Questie
already covers the map in quest icons, and two addons drawing the same quests is worse than
either alone — you cannot tell whose icon you are looking at, and clicking the wrong one
does nothing you expected. `/qef pins on` turns them on anyway, for running them alongside
or instead; `/qef pins off` never draws them. `/qef status` says which it is doing and why.

**They follow you up to the continent.** A step's coordinates belong to its own zone map, so
matching them against the open map drew pins only while you were looking at that exact zone
- open Eastern Kingdoms and the map went empty, which is the opposite of useful for a run
that crosses three of them. Each point is now converted to world coordinates and measured
against the open map's own rectangle, taken the same way, so the ratio comes out right
without this code needing to know which way the world's axes run. A point landing outside
the open map is not drawn, and two different continents never match.

**The pool has to be re-registered before every draw.** `AcquirePin` looks a pool up by
template name and, finding none, builds one itself from an XML template of that name —
which for an addon that ships no XML does not exist, so the frames it makes carry none
of the pin mixin and the very next line of Blizzard's own code calls a method they do
not have. Worse, it keeps that broken pool for the session, so losing the race once
means losing it until you reload. Registering at login is not enough on its own: the
canvas empties `pinPools` when it loads, the world map is load-on-demand on some builds,
and a map addon can replace the frame entirely. So the pool is put back in front of the
canvas's own before each draw, which costs one table comparison.

There are also two pool systems, and which one the client uses decides whether the frames
come from our function or from the pool itself. On the newer one a pool made with
`CreateFramePool` hands back bare frames whatever its `createFunc` says, which lands in the
same place: no mixin, and Blizzard calling a method that is not there.
`CreateUnsecuredRegionPoolInstance` honours it, so it is used wherever it exists.

They go on the map the way Blizzard's own pins do — a `MapCanvasDataProviderMixin` provider,
and a pin pool seeded into the map's own `pinPools` under this addon's template name so
`AcquirePin` finds it without an XML template to go with it. That is the same route
HereBeDragons takes, which is how Questie's pins get there, so it holds up under a map addon
reskinning the frame: the pins belong to the canvas and pan and zoom with it.

The pins are **painted art, shipped with the addon** — the one place it does ship art rather
than borrowing the client's. A tinted interface glyph does not read at twenty pixels against
a painted map; a teardrop with a gold frame does. Each file is a 128×128 uncompressed 32-bit
TGA in `art\`, which is what the client will load: powers of two, no RLE. The pin is scaled
to the full height of the texture and the spare width left transparent, so `Art.pin` records
how much of each one is actually pin (`u`) and the drawing code cuts the padding off with
`SetTexCoord(0, u, 0, 1)` — without that the art stretches.

**One style, chosen once.** The twelve textures are six styles of two marks, and a map
wearing all six at once is a fairground - so every pin wears the style you pick and the
shape carries the meaning: a bang for somewhere to go, a query for something to hand in.
The exception is the step the guide is pointing at, which always takes the glowing style,
because that one is not decoration. Slate, blue, old parchment, gem, green and glow are
the six; the settings page has them and so does `/qef pins style <name>`.

**One pin per place, not per spawn.** An objective NPC is recorded once for every spawn
point it has, and a camp of them is a dozen records a few yards apart. Drawn literally
that is a dozen identical pins in a huddle, saying nothing a single pin does not and
burying the rest of the zone. Spawns within six percent of the map are gathered into one
pin at the middle of them, four camps per quest at most, busiest first.

**A pin is a control, not a label.** Click one and the game's own marker goes on that
spot - the arrow in the world, the distance, the dot on the minimap - and the in-game
navigation setting is switched on for you if it was off, because a waypoint placed while
that is off looks exactly like an addon doing nothing. A quest already on the checklist is
left to the guide instead, which places the marker itself and moves it on as you finish
each step; taking that over from a click would strand it. The coordinates used are the
real ones, not the ones the pin is drawn at, so clicking a pin on a continent map marks
the spot in its zone rather than a stretch of coastline.

**Shift-click opens it here**, in the browser, with the chain, the rewards and everything
else the addon knows - the game's own convention for "tell me more" rather than "act on
it". Both are written on the pin's tooltip, since a pin does not look like something you
can click.

**The game's own quest pins step aside** while ours are drawn, so one turn-in is not
marked twice by two addons with the hover going to whichever drew last. The value the
client's `questPOI` setting had beforehand is written down and put back when ours go off,
rather than being reset to whatever we assume the default is. Settings has the switch, and
so does `/qef pins blizzard`.


What gets drawn, and nothing past it: where to pick a quest up, where to hand it in, who is
in the way when it is locked, and the creatures a quest in your log names in its objectives -
which are also what that quest's own step points at, so a quest you are part way through is
marked where the work is rather than nowhere at all.
Objectives that are items or objects need a lookup this does not do yet — what drops that
item, where that chest is — so a gather quest shows its giver and its turn-in and no pins
out in the field. An NPC is drawn at up to eight of its recorded spawns, and a zone at up to
forty objective pins, which is where a map stops being readable rather than where it gets
slow.

## Where the chain goes from here

At a quest giver the dialog has already told you what the quest asks for and what it pays.
What it never tells you is that this is the first of four, that the third one is in a
dungeon, or that the real reward is at the end — which is the whole question when you are
deciding whether to take it.

So the preview's chain block is the **line forward**, not just the quest after this one:

```
Chain
  Step 2 of about 5
  Next:  [24] Deviate Eradication
  then:  [25] Alpha Strike
  then:  [26] Leaders of the Fang
  plus 2 other branches from here
  Chain ends at step 5 with
    Savage Trodders   lvl 29 Feet, Leather
```

**A step filed under another zone says so**, with an arrow: `then: [36] Wand over Fist →
Wetlands`. A chain that starts in Stormwind and finishes in the Wetlands is a different
proposition from one that stays put, and nothing else on the line would tell you. Steps in
the same zone as the quest you are looking at say nothing, so the arrow only ever marks a
move.

The path followed is the one reaching the far end of the chain, which is its main line.
Branches are counted rather than drawn, because a preview that forks is a preview nobody
reads — the browser's **Chain** tab draws the whole tree for anyone who wants it. How many
steps are listed follows the verbosity setting: one at brief, four at normal, six at
everything.

## The window

`/qef` opens it. A left rail, four pages, no tabs and no nested option trees.

**Browse quests** — search by name or quest id, narrow by zone, by your own faction, by
dungeon quests only, or by quests that reward something. The faction chip starts on, since
the usual question is which quests *you* can pick up; quests open to both sides are never
filtered out by it. The list carries level, name and a dungeon marker and nothing
else; everything else is in the detail pane on the right, which shows the same preview the
tooltip does. Hovering a reward line there gives you the real item tooltip.

The quest index behind it is built the first time you open the browser rather than at login,
so it costs nothing if you never use it.

**Results are grouped into their chains.** Each quest is indented under the one it follows,
with a connector drawn between them, so a chain reads top to bottom in one block instead of
being scattered down the list by quest level. Level order still decides the chain starts and
the order of branches, so a grouped list is a level-ordered list at every fork.

Only quests that matched your filters are listed — nothing is added to fill a gap. When a
quest's own predecessor was filtered out, it is indented under its nearest predecessor that
*is* in the list, so an indent always means "comes after the row above it". Past six levels
deep the indent stops growing, because the name is worth more than another step of margin.
`/qef chainorder` or Settings gives you the flat level-ordered list back.

## The minimap button

Click it to open the window, right-click for settings, middle-click for the checklist strip,
and drag it round the minimap's edge to park it somewhere clear — the angle is saved, and
`/qef minimap reset` puts it back. Its tooltip carries the checklist's progress, since that
is the thing worth knowing before deciding to open anything.

It is written rather than embedded. LibDBIcon is the usual way and a good one, but it brings
LibStub and an embed with it, and the layout underneath is four textures and an angle —
less code to write than to embed. The radius is measured from the minimap rather than
assumed, so a UI that resizes the minimap does not leave the button floating off the edge.

## The dungeon checklist

A dungeon's quests are the ones people miss, because hardly any of them are handed out at
the entrance. They come from a town two zones away, from an NPC standing in a cave you have
no other reason to visit, and from the end of a chain you have not started. By the time you
are at the summoning stone it is too late to go and get them.

**Dungeon runs** is the page for that. Pick a dungeon on the left, and every quest the game
files file under that dungeon is listed on the right — wherever it is actually given out.
Tick the ones you want, or press *Add what is left*, which adds everything you have not
already picked up or finished. The other faction's quests are left out entirely, since they
cannot be picked up at all.

What you tick goes on a checklist, kept **per character**, and the strip appears beside the
game world.

### One step at a time

The strip does not list quests, it lists **steps**. Each quest shows the one thing it needs
next, decided by the state it is in:

| | step | what it means |
|---|---|---|
| `!` | **Pick up** | you can take it now, and the line names who from |
| hourglass | **Finish** | it is in your log, pointed at the creatures it names |
| `?` | **Hand in** | it is complete, and the line names who to hand it to |
| lock | **Unlock** | nothing walkable was found — the line names what is in the way |

**A locked quest shows you the way out of it, not the lock.** "Unlock Heart of Disruption"
tells you nothing you can act on; what you need is the quest standing in its way and where
*that* one starts. So a locked quest's line becomes that quest's own step — `Pick up An
Alarming Request`, `from Emissary Jacques, Hillsbrad Foothills (54, 48)` — and says what it
unlocks underneath. If the prerequisite is locked too, the walk carries on back, up to five
quests, until it reaches one you can actually do. Only when nothing walkable is found does
the line fall back to naming the lock.

Two of your quests waiting on the same prerequisite are **one errand, not two**, so they
share a line that says what it unlocks. So does a prerequisite that is on your list in its
own right, rather than being drawn once as itself and again under everything it unblocks.
Dropping a shared line drops every quest it was clearing, and says so.

Turn-ins matter as much as pick-ups and are the part people forget. A quest is rarely handed
back to the NPC who gave it out, and often not even in the same zone, so the hand-in is a
step of its own with its own place on the map.

Steps are **grouped by the zone you have to be standing in**, so one trip clears a group
rather than you criss-crossing a continent one quest at a time. The zone you are in sorts to
the top; a zone on another continent is marked, and clicking its heading opens the travel
directions for it. Within a group hand-ins come before pick-ups, since the hand-in is usually
what you are already standing next to.

**The zone you are standing in is put in walking order.** Nearest step first, then whatever
is nearest to *that*, and so on — a route rather than a list, with the heading reading
`4 in order` instead of `4 steps`. The marker follows the same order, so finishing a step
sends it to the nearest remaining one rather than back across the zone.

It is nearest-neighbour, not a shortest path. The exact answer is the travelling salesman
problem, and the inputs do not deserve it: a handful of points and straight-line distances
that know nothing about the cliff or the river in between. It is still worth doing, because
what it replaces is an order with no relation to the ground at all. Only your current zone
is ordered this way — it is the only one there is a starting point for — and steps with no
recorded place sit at the end of their group. `/qef walkorder` turns it off.

A finished quest leaves the list and becomes part of a single line at the bottom —
`3 finished — click to clear`.

### The marker follows you

The game's own marker — Blizzard's user waypoint with supertracking, the same thing `/way`
gives you: a map pin, a minimap arrow and the floating marker in the world — sits on the step
you are on, and **moves to the next one when that step is done**.

What counts as done is the quest's state changing, not your position. Standing on a quest
giver is not the same as having the quest, and a marker that jumped away while you were still
reading the quest text would be worse than no marker at all. Arriving is still noticed — the
step says `here` and the strip says so — but the marker only moves when you accept, hand in,
or unblock something. In practice that is a second after you arrive, and it is never wrong.

The marker holds its step even when the order changes underneath it: walking into a zone
promotes that zone to the top of the list, and a marker that slid to a different quest while
you were on your way to this one would be infuriating.

Some steps have nowhere to point. A quest in your log has no marker, because objective
locations are not in the data this addon reads and inventing one would be worse than saying
nothing; the marker skips to the next step that does have a place. If the client refuses a
waypoint on a particular map — which Forever does for some of them — that step is skipped too
rather than the whole list giving up.

**Clicking a step answers "where is that?" on its own.** It puts the marker on the place,
names the NPC, the zone and the coordinates in chat, and — when the place is on a map you
are not standing on — opens the travel directions as well. Hovering a step says the same
thing without changing anything, along with what the line unlocks and what a right-click
would drop. A zone heading opens the directions for that group.

Click any step to put the marker on it yourself; it stays there until that step is done.
`/qef guide next` leaves the current step alone and marks the next one, `/qef guide reset` puts
every skipped step back in play, and `/qef guide off` stops it and takes the marker away — but
only if the marker is still the one it placed, never a pin you have since set yourself.

### The rest of it

A step's box ticks the quest off by hand, for the cases the client cannot see, and
right-clicking a step takes the quest off the list. The strip hides itself when the list is
empty, and the × hides it without emptying it.

Quests can also be added one at a time from the browser's detail pane, which is usually how
a chain quest with a dungeon ending finds its way onto a list.

`/qef plan [dungeon]` opens the page, matching loosely — `/qef plan wailing` finds Wailing
Caverns. `/qef checklist` prints the list in chat, `/qef tracker` shows or hides the strip, and
`/qef tracker reset` puts it back by the right-hand edge if it has been dragged off a screen
that has since changed size.

## Controller layout

Three things make a mouse interface unusable on a pad, and the controller layout addresses
all three rather than just making the buttons bigger:

- **Nothing can be reached without a cursor.** Every control is registered as a focus target
  in one of four columns — the nav rail, the toolbar, the results list, the detail pane — and
  the d-pad moves between them. A bracket marks what has focus. The list and the preview pane
  take the movement first and only hand it on once they have run out of rows to scroll, so a
  long list behaves like one continuous surface instead of a trap you have to step out of.
- **Anything behind hover is invisible.** Focusing a control runs the same tooltip hovering it
  would, so nothing is only discoverable with a mouse.
- **The buttons are unlabelled.** A bar along the bottom says what each one does *here*, and
  changes as focus moves. Face buttons are named by position, so Settings switches the names
  between `A B X Y` and the PlayStation shapes.

| Button | Does |
|---|---|
| D-pad / left stick | Move focus; in the list, change the selected quest |
| A | Activate what has focus |
| B | Back through the chain you followed, or close |
| X | Waypoint to the selected quest's giver |
| Y | Its Wowhead link |
| LB / RB | Previous / next view |

Rows grow from 32 to 40px, and the three dialogs take B to dismiss. **Accept does not start
the sweep** from the intro — a tutorial should not be one accidental press away from kicking
off a long job.

### When it appears

`controller` defaults to **auto**, and on auto the layout appears **only when a pad is
actually connected**. Detection is deliberately strict, and every step has to say yes:

1. the client can report gamepad buttons to an addon at all;
2. the game's own gamepad support is switched on — a pad plugged in for another game
   delivers nothing here, so it does not count;
3. a device is really there. Where the client lists devices, the list must be non-empty.
   Where it only names an active device, that device is read back to confirm it exists,
   because an id of `0` is a number and "is this a number" is not the same question as "is
   there a pad".

It is re-checked at login, whenever the window opens, whenever a pad is connected or
disconnected, and whenever a gamepad CVar changes. `/qef controller` prints the answer and the
reason for it, and `/qef api` lists the three gamepad calls it went on.

`/qef controller on` forces the layout without a pad — the navigation is useful from the
keyboard too — and in that case the hint bar names **keys rather than face buttons**, because
telling someone to press A when they are holding a keyboard is worse than no hint at all.
`off` keeps it away entirely.

Two notes on the implementation. Gamepad buttons arrive through `OnGamePadButtonDown`, which
not every client has — every call into it is guarded, and where it is missing the layout
simply never switches on. The same actions are also on the arrow keys, but **only while the
controller layout is on**, because the arrow keys are turn-left and turn-right by default and
taking them from someone who did not ask for it would be rude. Keys the layout has no use for
are passed straight through.

**Enter is not one of the keys it takes**, and that was a bug worth the scar tissue. It used
to be the keyboard's accept, which meant that with a pad connected and a window open,
pressing Enter to talk did nothing at all: the window marked the key handled and stopped it
reaching the game, so the chat box never opened. Enter belongs to chat. The pad's A button
still accepts, and the hint bar names *Click* when it is listing keys. The handler also
stands down entirely while an edit box has focus, so typing in the search box moves the
cursor rather than the focus ring.

## Fitting

Preview rows **wrap instead of clipping**. A long objective or a travel step is routinely
wider than the pane, and a row that silently loses its tail loses the point of the line, so
each row is measured and given the height its text actually needs. The browser's preview
pane scrolls with the mouse wheel for the same reason: a verbose quest with long objectives,
six rewards, a chain and directions can run past the bottom, and a row that falls off is a
row you never learn exists. Quest names in the lists are the exception — those stay on one
line, because a wrapped name would spill into the fixed-height rows either side of it.

**Settings scrolls.** The page has two columns and they have outgrown the window as features
arrived, so the rows live in a scroll child that is as tall as the longest column rather than
as tall as the window. The thin indicator on the right appears only while there is more than
fits, and the page snaps back to the top if the window grows enough to show everything —
otherwise it would keep an offset and look as though it had lost its first rows.

Every window **scales itself down if it would not fit your screen** at your UI scale, to a
floor of 65% where text stops being readable. A window taller than the screen loses its
bottom row of buttons and cannot be dragged back into view, which is a worse failure than
slightly smaller text. This is rechecked whenever the window opens and when the resolution
or UI scale changes.

Each quest shows its **faction** (an Alliance or Horde emblem, nothing when either side can
take it) and its **status** for this character: completed, in your log, ready to turn in,
locked behind a prerequisite, or the wrong faction. Completed quests are dimmed rather than
hidden, so a chain still reads as a whole. A key at the right of a row marks a dungeon quest.

The marks are the only thing here that has to be learned, so **What do the marks mean?**
above the list opens a legend for them, and the first-run intro teaches the same one.

The detail pane has two tabs:

- **Preview** — the same rows the tooltip and side panel draw.
- **Chain** — the entire chain as an indented tree, from its very first quest to its last,
  every step marked with its status and the one you are looking at highlighted. This is the
  quickest way to see where a chain begins and how much of it you have already done.

Quest names are **links** everywhere they appear. Click a prerequisite to jump to it, click
again to keep walking back, and use **Back** to retrace. That is the answer to "I cannot pick
this up, so where does it start?".

The zone picker has its own filter box, so you type "ungoro" rather than scrolling to it.
A quest you cannot take yet is marked **locked** on its name, in the list, in the chain tree
and in the preview header, with the earlier quests you need listed underneath as links.

**Waypoint** sets a Blizzard map pin on the quest giver — the real user waypoint, so it shows
on the map, the minimap and the navigation arrow, exactly like a `/way` pin. It is offered
only when the quest giver has a recorded location.

**Wowhead** hands you the article's address. The client cannot open a browser and chat will
not make a URL clickable, so the link comes up in a small window with the text already
selected: Ctrl+C, Escape. It points at Classic Wowhead, since this is a Classic-era ruleset.
Quest ids come from QuestieDB, which is built for this server, so a quest the realm has added
or rewritten can have an id Wowhead does not know — the window says so rather than pretending
every link is good. `/qef wowhead [id]` does the same from the keyboard, and `Link.base` in
`Link.lua` is one line to change if you want a different site.

**Reward sweep** — see below.

**Settings** — every toggle, plus where the preview appears and how much it says.

## Travel directions

When a quest giver is on another continent, the preview adds a **Getting there** block and
the Waypoint button opens a small **Getting there** window: which boat or zeppelin to take
and from where, numbered, with the map pin's result underneath. It is draggable, closes with
Escape, and has a **Don't show this** button that sends directions back to chat instead —
which is what `/qef routewindow off` and the Settings toggle do. `/qef route <id>` opens the
same window and prints what it based the answer on.

Directions were chat lines first. They are a window because they are read once and acted on,
and chat is the worst place for that: by the time you have mounted up they have scrolled away.

This is the one part of the addon that is **authored rather than derived**. Everything else
reads real data; there is no machine-readable table of boats and zeppelins anywhere on disk,
so `Travel.lua` spells the crossings out by hand. That makes it the only thing here that can
be wrong without the addon being able to tell, so its scope is deliberately narrow:

- it solves only the genuinely hard part, crossing between continents;
- within a continent it says "travel to *zone*" and leaves you to the flight network, rather
  than pretending to know a zone-by-zone route;
- it lists the crossings your faction can use and lets you choose, rather than claiming one
  is best.

The table is plain prose in one place and nothing depends on its wording, so correct it
freely if this realm differs. Turn the whole thing off with `/qef travel`.

## The reward sweep

QuestieDB has no reward data, and the server will answer for any quest id. The sweep walks
every quest id QuestieDB knows, asks the server about each one, and stores the exact rewards
that come back.

That makes it a better source than any quest site: **these are the answers from the realm you
actually play on**, so Forever's own changed and added quests are right rather than
confidently wrong, and the choice-versus-fixed split is known rather than guessed.

- A few requests a second by default — Gentle, Normal or Quick on the page.
- Pauses itself in combat.
- The position is saved, so it survives a reload, a logout or a disconnect; pressing Start
  again resumes rather than restarting.
- Quests already known are skipped, so re-running it only fills gaps.
- While it runs with the window closed, a small draggable strip shows progress. Click it to
  open the page; turn it off with `/qef toast`.
- Progress is also printed to chat at each quarter.

Quests the server will not answer for are counted as *no answer* rather than quietly skipped.
Those keep falling back to QuestieDB, with the usual caveat about the choice split.

## First run

The first time you log in, a short intro appears explaining the four things worth knowing and
offering to start the sweep. It never shows again; `/qef welcome` brings it back.

## Art

Most of what you see is the client's own art. Icons are Blizzard's, desaturated and tinted
to the theme so they read as monochrome glyphs rather than stickers on a dark panel; status
marks reuse the ready-check and gossip icons every client has; rules, markers and the accent
underline are flat colour textures. Faction emblems are the deliberate exception and keep
their own colours. `/qef api` reports which of these the client actually resolved. The two
things the addon does ship are the map pins and the window frames, both below.

**The palette is gold on warm dark**, themed to that art. The greys are the cool ones this
was built with, with their red and blue channels swapped — `16171B` became `1B1716`. That is
not a trick for its own sake: the luminance of every surface is unchanged, so each contrast
ratio the layout was tuned against still holds, and only the hue moves from blue-grey to
brown-grey. Gold on a blue-grey panel looks like gold on the wrong panel.

The accent is `F2C75B`, the gold of the frames and the pins, with `5E4414` — the shadow side
of the same gold — behind filled controls, and the corner art's gem blue kept as `gem` for
anything secondary. Green is left to mean one thing now that it is not the accent: finished.

**The painted frames** are the second place the addon ships art: gold corners on every
window and a thin compass-rose divider under the title. One corner texture does all four —
the art sits flush against its texture's top-left and the other three flip its coordinates,
so there is no second file and no way for the four to drift apart when one is redrawn. It is
padded to a square on the right and bottom only, because padding it evenly would stop the
art meeting the window's corner.

Each window is framed on all four sides: a corner at each corner and a gold rod along every
edge between them. The rod is one plain stretch of the divider art taken at native size, and
the two upright edges are that same texture turned a quarter turn with the eight-argument
form of SetTexCoord - the only way to rotate a texture that is not square without it
clipping itself. The rods are drawn first and the corners over them, so the joins are
covered rather than having to line up to the pixel.

The corners live on a frame of their own above the window, not on the window: a child frame
draws above every texture of its parent whatever the layer says, so corners drawn on the
window itself vanish behind the first thing anchored over them - which on the browser is the
nav rail, sitting exactly on the bottom left one. The divider belongs to the title bar for
the same reason, and straddles its lower edge rather than hanging below it, where it would
be a second piece of chrome competing with whatever the window puts at the top of its
content.

The art is built on every window whether or not it is switched on, and the setting shows or
hides it, so `/qef frameart` is something you watch happen rather than something you reload
for. Off leaves the plain hairline chrome the addon was built with.

**What sits in front of what**, since several of these can be on screen at once:

| Strata | What |
|---|---|
| `MEDIUM` | the checklist strip, the sweep progress toast |
| `HIGH` | the side panel and its tab — they ride along with a Blizzard frame |
| `DIALOG` | this addon's own windows, so one you opened deliberately covers the panel |
| `FULLSCREEN_DIALOG` | the welcome, directions and Wowhead dialogs |
| `TOOLTIP` | the preview tooltip |

Popups *inside* a window — the zone list, the legend — are raised by frame level rather than
by strata, so they cannot be orphaned from their window by a change like that one.

## Commands

`/qef` or `/questexplorer`.

| Command | Does |
|---|---|
| `/qef` | open or close the window |
| `/qef browse [text]` | open the browser, optionally searching |
| `/qef sweep` | sweep status; `start`, `pause`, `restart`, `reset` |
| `/qef settings` | the settings page |
| `/qef plan [dungeon]` | the run planner, on that dungeon if you name one |
| `/qef checklist [clear]` | what is on the checklist, in chat |
| `/qef tracker on\|off\|reset` | the checklist strip beside the world |
| `/qef guide on\|off\|next\|reset` | mark the step you are on, and what it is marking |
| `/qef pins auto\|on\|off\|available` | this addon's own map pins, and the zone's spare quests |
| `/qef minimap [reset]` | the minimap button, and where it sits |
| `/qef frameart` | the painted gold corners on windows |
| `/qef trackersteps` | toggle naming the quest giver under each checklist line |
| `/qef walkorder` | toggle walking order for the zone you are standing in |
| `/qef way [id]` | waypoint to a quest giver (the open quest if no id) |
| `/qef wowhead [id]` | the Wowhead link, in a box to copy |
| `/qef welcome` | show the intro again |
| `/qef route [id]` | directions to a quest giver, and what they were based on |
| `/qef travel` | toggle travel directions |
| `/qef routewindow` | toggle the directions window; off sends them to chat |
| `/qef chainorder` | toggle grouping the quest list into chains |
| `/qef controller auto\|on\|off` | the gamepad layout, and what it detected |
| `/qef on` / `/qef off` | enable or disable |
| `/qef mode tooltip\|panel\|both` | tooltip beside the list, a side panel, or both |
| `/qef verbosity 1\|2\|3` | brief, normal, or everything including data sources |
| `/qef objectives\|rewards\|chain\|dungeon\|rep\|ids` | toggle individual sections |
| `/qef questie` | toggle the map icon integration |
| `/qef questlog` | toggle the panel beside an open quest log |
| `/qef attach` | toggle the panel being flush against the frame rather than floating |
| `/qef minimise` | fold the panel into its tab, or open it back up |
| `/qef lookahead` | toggle asking the server about quests further along a chain |
| `/qef learn` | toggle remembering exact rewards |
| `/qef toast` | toggle the floating sweep progress strip |
| `/qef reset` | put a dragged panel back beside the quest frame |
| `/qef forget` | clear remembered reward data |

### Checking it against the real client

Rather than taking the table above on trust:

| Command | Shows |
|---|---|
| `/qef status` | what loaded, QuestieDB mode and build, Questie hook state |
| `/qef api` | every quest API this addon might use, and whether this client has it |
| `/qef index` | index statistics and the real reward coverage percentage |
| `/qef quest <id>` | every raw QuestieDB field for a quest, then everything derived from them |
| `/qef reward <id>` | resolve one quest's rewards and name the tier that answered |
| `/qef giver` | what the open quest giver frame returns, field by field, marking secret values |
| `/qef debug on` | verbose logging of hook wiring and server requests |

`/qef giver` run with a quest giver open is the quickest way to see exactly what this client
hands an addon.

**When a file does not load at all, none of that helps - read `Logs\FrameXML.log`.** A Lua
file that fails to compile is skipped silently: no popup, even with `/console scriptErrors 1`
on, because that shows runtime errors once the UI is up and this happens while addons are
still loading. The addon simply has one module fewer, and the first symptom is something
else finding a nil where it expected a table. The client writes the real message, with the
file and the line, to `<install>\Logs\FrameXML.log`:

```
Interface/AddOns/QuestExplorerForever/MapPins.lua:441: function arguments expected near 'and'
```

That one was `WorldMapFrame:GetMapID` where `WorldMapFrame.GetMapID` was meant - a colon
makes it a method call rather than a value, and Lua only allows `a:b` as part of a call, so
the whole file failed to compile over one character. `/qef status` ends with a `modules:`
line naming any of the addon's own modules that failed to register, which is the quickest
way to notice it has happened at all.

## Questie integration

When Questie is loaded, the preview is appended to its map and minimap icon tooltips by
hooking `MapIconTooltip.ShowOnTooltip` and the `_Rebuild` closure it installs, so the preview
survives Questie's own modifier-key redraws. When Questie is absent nothing is installed and
no error is raised — `/qef status` reports the state either way. Questie is also used, when
present, to resolve a quest title to an id on the rare frames that only expose titles.

## Files

| File | Role |
|---|---|
| `Core.lua` | namespace, settings, events, secret-value guards, frame-budgeted work |
| `Source.lua` | all QuestieDB access, behind guards |
| `Index.lua` | the reverse indices (chain edges both ways, reward items), built asynchronously at login |
| `Rewards.lua` | the four-tier reward resolver and the server request queue |
| `Chain.lua` | chain root, forward walk, final rewards, dungeon gating |
| `Render.lua` | quest id to preview rows |
| `Tooltip.lua` | the addon's own tooltip and the row appender others reuse |
| `Panel.lua` | the side panel, with hoverable reward lines |
| `Hooks.lua` | quest detail, greeting and gossip wiring |
| `QuestieBridge.lua` | Questie map icon tooltip integration |
| `Sweep.lua` | the reward sweep: pacing, resume, harvesting |
| `Search.lua` | the browser quest index and its filters |
| `Widgets.lua` | the theme and every control the window is built from, scrolling included |
| `Window.lua` | window shell, nav rail, view routing |
| `Browse.lua` | the quest browser |
| `Checklist.lua` | the per-character run list, and the step each quest needs next |
| `Guide.lua` | the game's marker, moved from step to step |
| `MapPins.lua` | this addon's own world map pins, and when to stay out of Questie's way |
| `MinimapButton.lua` | the button on the minimap, and the angle it remembers |
| `Tracker.lua` | the checklist strip beside the game world |
| `Plan.lua` | the dungeon run planner page |
| `Views.lua` | sweep and settings pages, floating progress strip |
| `Welcome.lua` | the first-run intro |
| `Art.lua` | icons, faction emblems, status marks, decoration |
| `Waypoint.lua` | Blizzard user waypoint, with verification |
| `Travel.lua` | the authored continent crossings and route text |
| `Route.lua` | the pop-out directions window |
| `Link.lua` | Wowhead URLs and the copy window |
| `Controller.lua` | gamepad focus model, input, hint bar |
| `Debug.lua` | the `/qef status|api|index|quest|reward|giver` reports |
| `Options.lua` | slash commands |
