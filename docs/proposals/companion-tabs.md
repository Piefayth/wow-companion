# The Companion window's tabs

The player, 2026-11-11 (shot `shots/companion-tabs-1238.png`): the tabs must
belong to the panel, joined to it, with character, in World of Warcraft's own
style. Design only. Paths are under `docs/wow-ui-source/Interface/AddOns/`.

## Why five tries failed: the tabs were on the wrong edge

Every try put text tabs on the **top** edge, inside the panel, standing on the chat
well. Blizzard never does that in this build. The top tabs it does draw
(`PanelTopTabButtonTemplate`, `TabSystemTopButtonTemplate`) hang off a frame's
outer border. The warm `uiframe-tab` art is cut to merge with that metal edge
(`SharedXML/Mainline/SharedUIPanelTemplates.xml:932`). On the cool stone inside
the frame it looks pasted on, as the player said. `MinimalTabTemplate` is the
settings panel's flat tab and has no edge art to join anything. The top band
those tabs stand in is ButtonFrameTemplate's **attic**, the 60 px inset offset
(`PANEL_INSET_ATTIC_OFFSET = -60`, `SharedUIPanelTemplates.lua:9`). That band is
the "gutter" from try 3.

**What Forever itself does.** Forever's windows (the `Camelot` folders, the game
type in Blizzard's manifests) put their tabs on the frame's **right side, outside
it, tucked under its border**:

- Collections: `Blizzard_Collections/Camelot/Blizzard_CollectionsTabs.xml:4-18`. The container is anchored `TOPLEFT` → frame `TOPRIGHT`, and the tabs inherit `LargeSideTabButtonTemplate`.
- Professions: `Blizzard_Professions/Camelot/Blizzard_ProfessionsFrame.xml:13-60`. Tabs are stacked `TOPLEFT` → previous `BOTTOMLEFT` (0, -2).
- Inspect: `Blizzard_InspectUI/Camelot/Blizzard_InspectUI.xml:4`.
- Group finder: `Blizzard_GroupFinder_VanillaStyle/Blizzard_LFGVanilla_ParentFrame.lua:92`.
- Communities uses the classic spellbook side tab. Its Chat tab is `Interface/Icons/UI_Chat` (`Blizzard_Communities/CommunitiesFrame.xml:368-376`).

So the native answer is side tabs. With the tabs off the top, the attic goes too
(`ButtonFrameTemplate_HideAttic`, `SharedUIPanelTemplates.lua:74`). The wells rise
to the title bar's foot and the gutter is gone.

## Common to every option

- **Wells rise.** Chat well and conversation well `TOPLEFT`/`TOPRIGHT` y go from -60 to -24 (`PANEL_INSET_TOP_OFFSET`, `SharedUIPanelTemplates.lua:8`). That gains 36 px of transcript. Keep the lip shadow (`ShadowOverlay-Top`) as it is: it now falls from the title bar onto the chat well, which is where Blizzard's attic-less frames carry it. `applySize` loses any reserve it keeps for tabs at the top.
- **The page name moves to the title**, as Collections does (`Blizzard_Collections/Shared/Blizzard_Collections.lua:110`, `self:SetTitle(...)` per tab). Use `frame:SetTitle("Companion")` on Chat and `"Companion: Tools"`, `": Status"` or `": Errands"` on the others. Side tabs are icons, so the title is where a couch reader sees which page is open.
- **Controller.** Each tab gets `WC.MarkFocusable(tab)`. Nothing is bound. SmartNavigation clicks a focused button through `MouseDown`/`MouseUp` (`Blizzard_GamepadSmartNavigation/SmartNavigation.lua:1639-1651`), which fires `OnClick` on a Button or CheckButton. Do not define `OnSmartNavClick` on our frames (the CLAUDE.md rule about manager-read fields). Tooltips show on cursor focus through the template's `OnEnter`.
- **Removed in the same change.** Remove `MinimalTabTemplate`, `tab.Text`, the width-from-text code, the `chatWell + 5` level comment ("above the well's border and its top shadow"), and the "standing on the wells' top edge" comments. Update the window-frame proposal's tab lines and CLAUDE.md if it names the tabs.
- **Screen room.** The window sits at the upper left with open world to its right, so roughly 50 px of tabs off the right edge fits. The clamp (`SetClampedToScreen`) needs `SetClampRectInsets(0, -TAB_W, 0, 0)` so the tabs never leave the screen. This is the one extra line.

## Option A (recommended): Forever's large side tabs, `LargeSideTabButtonTemplate`

**Picture:** four square icon tabs (chat bubble, wrench, pocket watch, scroll)
come out of the window's right metal edge, stacked from the top. The open one has
a gold rim and its icon lit, as in Forever's Collections journal.

- **Template.** `CreateFrame("Button", nil, frame, "LargeSideTabButtonTemplate")` (`SharedXML/Mainline/SharedUIPanelTemplates.xml:1008`). A Button, as Blizzard's own `CollectionsJournalTab` is (`<Button ... inherits="LargeSideTabButtonTemplate">`, `Blizzard_CollectionsTabs.xml:4`), so it is a real button to the cursor and has `OnClick`. Call `SidePanelTabButtonMixin.OnLoad(tab)` explicitly if the template's own OnLoad has not sized it (`SharedUIPanelTemplates.lua` ~310-330: size from the `common-sidetab` atlas, the icon centred at (-3, 0)).
- **Art.** All of it comes from the template: `common-sidetab` (background), `common-sidetab-selected` (the open tab's rim, `SetChecked`), `common-sidetab-hover` (highlight), and `common-sidetab-mask` (rounds the icon). No generated texture.
- **Icons.** Set with `tab.Icon:SetTexture(path)` and then `tab:SetFillToInterior(true)` (the Collections way, `fillToInterior=true`; 50 px default extent). Every icon is in Blizzard's source:
  - Chat: `Interface/Icons/UI_Chat`, Communities' own chat tab (`CommunitiesFrame.xml:371`).
  - Tools: `Interface/ICONS/INV_MISC_WRENCH_01` (`Blizzard_Console/Blizzard_Console.xml:248`).
  - Status: `Interface/Icons/INV_Misc_PocketWatch_01` (`Blizzard_TimeManager/Mainline/Blizzard_TimeManager.xml:56`).
  - Errands: `Interface/Icons/inv_misc_scrollunrolled01` (`CommunitiesFrame.xml:421`).
- **Tooltip.** `tab.tooltipText = name`. The mixin shows it on enter (`SidePanelTabButtonMixin:OnEnter`), so the cursor landing on a tab names it.
- **Anchors.** Tab 1 is `TOPLEFT` → `frame` `TOPRIGHT` at (-2, -24): level with the wells' top, its root 2 px under the frame's metal edge. Tabs 2 to 4 are `TOPLEFT` → previous `BOTTOMLEFT` at (0, -2), Professions' spacing (`Blizzard_ProfessionsFrame.xml:29`).
- **Levels.** `tab:SetFrameLevel(frame:GetFrameLevel())`. The ButtonFrame's border (its NineSlice child, above the frame's level) then draws over the tab's root, so the tab comes out from under the metal, the join Blizzard's side tabs rely on. Do not raise the tabs above the border. That would put them back to standing on the frame.
- **Selected and unselected.** `SelectTab(id)` calls `tab:SetChecked(i == id)` on each tab (`SidePanelTabButtonMixin:SetChecked`: the gold `-selected` rim shown or hidden). Unselected tabs are the plain dark slate tab with the icon at full colour, as in Collections. `OnClick` calls `frame.SelectTab(self:GetID())`. The template's `OnMouseUp` already plays `IG_CHARACTER_INFO_TAB` and presses the icon in.
- **Why first.** It is this build's own tab: dark slate with a gold rim, the same family as the ButtonFrame's dark metal and our stone. That gives it the character the minimal tabs lacked. It joins the panel the way Forever's Collections, Professions and Inspect windows do. It frees the attic.

## Option B: the classic spellbook side tab, `RightSideTabTemplate`

**Picture:** the same stack off the right edge, but in the old spellbook's
skill-line tabs: smaller 32 px icons in a brown-and-gold bookmark, with a white
square glow on the open one.

- **Template.** `CreateFrame("CheckButton", nil, frame, "RightSideTabTemplate")` (`SharedXML/Shared/Tabs/RightSideTab.xml:3`, mixin `RightSideTab.lua`). The art is `Interface\SpellBook\SpellBook-SkillLineTab` (64x64 at (-3, 11)). The checked texture is `Interface\Buttons\CheckButtonHilight` and the highlight is `ButtonHilight-Square`.
- **Icons.** The same four, set with `tab.Icon:SetTexture` after creation. The template's `OnLoad` reads `self.iconTexture`, so set that field before the first show, or call `SetTexture` directly. `tab.tooltip = name`.
- **Anchors.** Tab 1 is `TOPLEFT` → `frame` `TOPRIGHT` at (0, -36), Communities' first tab (`CommunitiesFrame.xml:375`). The rest are `TOPLEFT` → previous `BOTTOMLEFT` at (0, -20) (`CommunitiesFrame.xml:389`).
- **Levels.** At the frame's level, as in A, so the bookmark's root sits under the border.
- **Selected and unselected.** `OnClick` is the mixin's (sound plus `SetChecked(true)`). Hook it with `tab:HookScript("OnClick", ...)` to call `frame.SelectTab`, and have `SelectTab` call `SetChecked(i == id)` on every tab. The open tab carries the additive square glow. The others are the bare bookmark.
- **Against.** It is the older, warmer art (brown bookmark), the same mismatch as try 4 on a smaller scale. Its 32 px icons read worse from a couch than A's 50 px.

## Option C: bottom tabs hanging under the frame, `PanelTabButtonTemplate`

**Picture:** text tabs in Blizzard's dark-red-and-gold tab art hang from the
window's bottom metal edge, as under the character and friends frames. The open
tab is taller and merges into the border.

- **Template.** `CreateFrame("Button", nil, frame, "PanelTabButtonTemplate")` (`SharedXML/Mainline/SharedUIPanelTemplates.xml:932`). Forever's friends frame uses it (`Blizzard_FriendsFrame/Camelot/FriendsFrame.xml:384`, tabs at 822).
- **Anchors.** Inspect's (`Blizzard_InspectUI/Camelot/Blizzard_InspectUI.xml:15-30`): tab 1 is `TOPLEFT` → `frame` `BOTTOMLEFT` at (11, 2), and the rest are `LEFT` → previous `RIGHT` at (-16, 0). Size with `PanelTemplates_TabResize(tab, 0)` and select with `PanelTemplates_SetTab(frame, id)` (`frame.Tabs` is filled by `parentArray="Tabs"`).
- **Levels.** At the frame's level. The active tab's `uiframe-activetab` art overlaps the border by 2 px, which is how it joins.
- **For.** It keeps words on the tabs, and the player called it "fine" once (try 1).
- **Against.** It sits under the window, below the legend row, where a TV viewer's eye is not drawn. It does not free the attic by itself (the attic could still be hidden, as in the common section). It is the retail look rather than Forever's own.

## Recommendation

**Option A.** Build it in one change:
1. Remove the attic and raise the wells.
2. Add the four `LargeSideTabButtonTemplate` Buttons off the right edge.
3. Show the page name in the title.
4. Remove the minimal tabs and every comment and anchor that served them.

Check it with a shot (`tools/shot.ps1`): the tab roots should be hidden under the
right border, the gold rim should be on the open tab, and the cursor should reach
each tab and name it in a tooltip.
