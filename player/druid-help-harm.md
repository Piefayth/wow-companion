# Help/harm scheme for Pietra (Druid 21), proposal only

## What help/harm macros trade

Pros
- One button per pair of spells: the target decides which one goes off, so a
  controller's limited chords stretch twice as far.
- A fallback `[@player]` means a heal with no friendly target heals you, with
  no retargeting. That is a big deal on a pad, where swapping targets is slow.
- `[form:n]` lets bars that don't page in forms (L2, L2+R2) still do something
  useful in cat or bear form.

Cons
- No mouseover on a controller, so `[@mouseover]` is useless. Everything keys
  off the hard target, the soft targets, or yourself.
- The gamepad UI soft-targets enemies (`softenemy`), and Blizzard's own
  TargetLogic hard-targets that unit when a harmful spell is cast with no
  target. A plain `[harm]` checks only the hard target, so with nothing
  targeted the macro would heal you, not Wrath the mob in front of you. Fix:
  test `[@softenemy,harm]` explicitly. Not yet measured on this client.
- Holding an enemy target while you need to heal a friend means you heal
  yourself. Fine solo; in a group you must target the friend.
- Macros cast the highest rank, so no downranking (HT 5188, Regrowth 8938).
- One icon and tooltip per button, which shows whatever the current target
  would get (`#showtooltip` follows the conditionals).
- Caster spells in a form fail unless the macro cancels the form. Adding
  `/cancelform [help]` is possible, but it will drop you out of bear when you
  meant to stay in it.

## Caster pairs (6 buttons for 13 spells)

1. Wrath / Healing Touch
   `/cast [@target,harm,nodead][@softenemy,harm,nodead] Wrath; [@target,help,nodead][@player] Healing Touch`
2. Moonfire / Rejuvenation: the instant pair, same shape.
3. Starfire / Regrowth: the big casts, same shape.
4. Entangling Roots / Nature's Grasp: root what's targeted, else Grasp yourself.
5. Faerie Fire / Cure Poison (Cure on the friend, else yourself).
6. Hibernate / Rebirth / Revive:
   `/cast [@target,help,dead,combat] Rebirth; [@target,help,dead] Revive; [@target,harm][@softenemy,harm] Hibernate`

## Forms

The R2 bar already pages to the stance bar in cat and bear (Claw, Shred, Rip,
Maul, Swipe...), so those need no macros. For the bars that don't page, make
buttons form-aware so one chord works everywhere, e.g.
- `[form:1] Demoralizing Roar; [form:3] Prowl; <caster pair>`
- `[form:1] Growl; [form:3] Rip; ...`
Form numbers at this level: 1 bear, 2 aquatic (if learned), 3 cat. Check them
in game.

## Layout

- R2 bar (combat): Wrath/HT, Moonfire/Rejuv, Starfire/Regrowth, Roots/Grasp,
  Faerie/Cure, Hibernate/Rez, all on the face buttons and d-pad. The stance bar
  covers forms.
- L2 bar: Buffs wheel (L2 + left), plus form-aware utility.
- L2+R2 bar: mostly freed, room for Teleport: Moonglade, consumables, a
  cancelform button.

## To verify when implementing

- `[@softenemy]` and `[@softfriend]` as macro unit tokens on 1.60.1.
- The form indices.
- Whether `[@target,help]` with a soft friend and no hard target does
  anything sensible.

## Form economy (added after research)

What Forever players report (forums plus macro sites, unverified):
- No retail-style Prowl from caster. Prowl needs Cat Form ("must be in cat
  form"), and shifting costs a GCD, so going from caster to prowling is two
  GCDs whatever you do. A macro can make it one button pressed twice, not one
  press.
  `/cast [noform:3] Cat Form` then `/cast [form:3] !Prowl` (`!` stops a second
  press cancelling it).
- Heals from form: reports conflict on whether the game auto-unshifts.
  `/cancelform` is off the GCD and works in a macro, so `/cancelform [form]`
  then the heal leaves form and casts in one press. That is the fastest
  option any way it goes.
- Shifting costs mana (one guide says about 55% of base mana for bear/cat).
  Shifting back in after a heal is the real expense, and at low mana you can
  end up stuck in caster form. Prefer finishing a fight in form and healing
  after, or healing first and shifting once.

Implications for the layout:
1. Heals/cures on a bar that does not page (L2): each one is `/cancelform
   [form]` plus the help/harm cast, so the same chord works in or out of form,
   one press.
2. The R2 bar pages in form, so put the damage pairs there (caster: Wrath/HT
   etc.; cat: Claw/Shred/Rip; bear: Maul/Swipe/Growl).
3. One "go cat" chord: caster → Cat Form, cat → Prowl. Likewise one "go bear"
   chord that shifts into bear, or Enrage once already there. On a pad these
   beat the L1+L2 wheel because they combine shift plus first action.
4. Never put `/cancelform` on the damage pairs: an accidental R2 press must
   not drop bear form.
5. Feral Charge belongs on the cat and bear pages (in Forever it charges in
   bear and gets you behind the enemy in cat), not the caster page. That frees
   197 there.

To measure in game before building: does casting Healing Touch in cat form
auto-unshift? Does Prowl in caster form error or shift? What does shifting
cost?

## The general rule (the earlier examples were arbitrary)

Classic-style rules, which Forever appears to follow (to be measured):
- Shifting into a form costs a GCD plus mana. Cat to bear directly costs one
  GCD, not two.
- Leaving a form (`/cancelform`, or re-pressing the form) is free: no GCD and
  no mana, but you lose that form's energy, rage and combo points.
- A form ability needs the form, and a caster spell needs caster form. There
  is no retail-style "the ability shifts you for you".

What follows:
- Caster → form ability is 2 GCDs (shift, then use). Form → caster spell is 1
  GCD (the exit is free). A detour out of form and back is 2 GCDs, a shift's
  mana and your resource.
- So every caster spell carries a free `/cancelform`: one press from anywhere.
- Every form gets one entry button whose first press shifts and whose next
  press is that form's opener (stealth, charge, taunt). That costs the
  unavoidable GCD and nothing more, where the L1+L2 wheel costs the same GCD
  plus the aiming.
- Pick a form per fight and stay in it: heal before the pull or after it, not
  mid-fight, unless it's an emergency.
- Damage pairs never cancel a form, so a stray press costs nothing.

## Layout proposal v2 (21:05, after all three forms were recorded)

- Top (no trigger): unchanged. Melon Juice, War Stomp, Cultivation, Apple.
- L2 (never pages; heals drop form in the same press, on friendly target else self):
  left Buffs wheel; up Cure Poison; right Cat Form, again Prowl; down Bear Form,
  again Enrage; square free; triangle Healing Touch; circle Rejuvenation; cross Regrowth.
- R2 caster page (193-200): left Faerie Fire; up Hibernate; right Nature's Grasp;
  down free; square Wrath; triangle Starfire; circle Moonfire; cross Entangling Roots.
  Duplicate Moonfire and caster Feral Charge removed.
- R2 cat page (265-272) and bear page (281-288): unchanged; Feral Charge stays on both.
- L2+R2: Teleport: Moonglade and Attack; old Moonfire/Hibernate/Roots/Grasp copies cleared.
- Form numbers for macros: bear 1, cat 2 assumed from the recorder (0 caster); verify.
- Reach checker still flags Feral Charge (Cat)/(Bear) falsely; checked by hand: 267, 283.

## Applied layout (21:42, measured in the export)

Stance page off (GamepadStanceBarOverride 1). Help/harm macros HH_* branch
[help] -> heal (drops form), [form:1] bear, [form:2] cat, [harm]/[@softenemy] caster damage, else self.
- Naked d-pad: left Items wheel (rule: bag items with a Use:), up Buffs wheel (MotW, Thorns, Moonglade).
- L2 face: square HH_Cross (Cure Poison / Feral Charge / Faerie Fire), triangle HH_Square
  (HT / Maul / Claw / Wrath), circle HH_Triangle (Rejuv / Swipe / Rip / Moonfire),
  cross HH_Circle (Regrowth / Roar / Shred / Starfire).
- R2 face: square Growl|Prowl, triangle Enrage, circle Bash (form-only; free in caster).
- L2+R2: right War Stomp, down Rez (Rebirth in combat, else Revive), square Hibernate,
  circle Entangling Roots, cross Nature's Grasp.
- Off the bars by request: Attack, Cultivation.
Player's rules: no duplicates; face buttons > d-pad (left thumb moves); frequent on face,
situational/long-cooldown (CC, rez) on L2+R2.
