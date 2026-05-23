# Moolah Help Content Style Guide

**Version:** 1.0
**Applies to:** every word a user reads outside of marketing — in-app help, help articles, tooltips, empty states, error messages, onboarding copy, alerts, settings descriptions, release notes (user-facing portion).
**Primary authority:** `guides/BRAND_GUIDE.md`. Where this guide and the brand guide conflict, the brand guide wins.

---

## 1. Purpose

This guide is for anyone — human or AI — writing help content for moolah.rocks. It tells you how to sound like Moolah while doing the practical work that good help has to do: get a user unstuck, explain a concept, walk through a task, set a correct expectation.

The job of help content is to let a user **finish the thing they came to do** with the least friction possible. Not to celebrate features. Not to teach finance. Not to apologise for the software.

If something in this guide makes a piece of writing weaker, name the conflict and propose a change. The guide is a tool, not a wall.

---

## 2. Brand Alignment (Top Priority)

`guides/BRAND_GUIDE.md` defines the product's voice, vocabulary, and visual identity. Help content is the brand speaking directly to a user mid-task — the alignment has to be tight, but the register shifts.

Read §2 (Brand Voice) and §11 (Key Brand Copy) of the brand guide before writing. The summary that follows is a reminder, not a substitute.

### What carries over from the brand guide

- **"Solid money. Chill vibes."** — Moolah is precise but never tense. Help inherits that: precise about what to do, relaxed about how it sounds.
- **"You" and "your."** Always second person, always singular. Never "users", "the user", "we recommend you".
- **Short sentences. Fragments are fine.** Especially in microcopy.
- **Plain-spoken.** "Where your money goes" beats "expenditure allocation." Every time.
- **Confident but warm.** We know what we're doing; we're not smug. We don't pad with "please" or hedge with "you may want to".
- **No corporate speak.** Reject *leverage, optimize, empower, take control, utilise, robust, seamless, streamline, holistic, solution*.
- **Don't be preachy.** Never lecture users about spending, saving, or budgeting habits. Moolah is a tool, not a coach.
- **Never promise what the app doesn't do.** No bank sync. No automatic categorisation by ML. No "we'll detect" or "we'll notify when". The app does what §10 of the brand guide says it does — nothing more.

### What shifts for help content

The brand-guide tone spectrum maps onto help like this:

| Brand-guide register | Where it lives in help |
|---|---|
| Marketing / playful | Almost never. Maybe an empty-state line on a fresh install. |
| Onboarding / warm | First-run flows, the introductory paragraph of a help article. |
| Feature descriptions | Concept articles, settings descriptions, tooltips. |
| Error states / alerts | Error messages, troubleshooting, validation. |
| Legal / privacy | Privacy explanations, iCloud sync claims, export disclosures. |

**Help content sits between feature descriptions and onboarding.** It's allowed warmth. It is not allowed cleverness that costs the reader a beat of comprehension. A pun that delays understanding is a bug.

### Lines that are off-limits in help

Even though the brand guide approves these, they belong in marketing — not help:

- "Your money, rock solid."
- "Solid money. Chill vibes."
- "Money stuff should be boring."
- "Set it up. Then go live your life."

In a help article, lines like these read as filler. Use them in landing pages and the App Store, not in "How to add a transaction".

---

## 3. Audience

Write for one person: a moolah.rocks user, on a Mac or iPhone or iPad, in the middle of trying to do something. Assumptions you can make:

- **They are competent adults.** Don't condescend. Don't define "click" or "drag".
- **They know finance basics.** They know what a credit card is, what a transfer is, what a category is in concept. They may not know what an **earmark** is — that's product-specific and worth defining.
- **They are not developers.** No code, no shell, no API references unless we're writing developer-facing docs (which this guide does not cover).
- **They came here from somewhere specific.** Most likely a "?" button, a search, or a Google. Assume context is partial. The article must stand on its own.
- **Their currency, locale, language, and platform vary.** Don't assume USD, dd/mm/yyyy, English idioms, or that "the Command key" is on every keyboard.

If you can't picture this person finishing the article and going back to the app one step closer to done, the article isn't right yet.

---

## 4. Surfaces and Length Budgets

Help lives on different surfaces. The voice is constant; the length and structure aren't.

| Surface | Typical length | What it must do |
|---|---|---|
| Tooltip / hover help | ≤ 12 words, single sentence | Disambiguate one control. No instructions. |
| Field-level hint | ≤ 20 words | Explain the field's purpose or accepted format. |
| Empty state | 1 line + 1 action | Say what would appear here, and how to make it appear. |
| Error message | 1 sentence + 1 next step | What happened, what to do. Never blame the user. |
| Confirmation / alert | Title (≤ 6 words) + body (≤ 25 words) + buttons | Make the destructive option obvious. |
| Settings description | 1–2 sentences | Say what the setting does and the practical effect of toggling it. |
| Onboarding step | 1 heading + 1–2 sentences + 1 action | One idea per step. Skippable where it makes sense. |
| Help article — concept | 150–400 words | Explain *what* and *why*. No procedures. Link to the task. |
| Help article — task | 200–600 words | One goal. Numbered steps. Verify-the-result line. |
| Help article — troubleshooting | 100–500 words | Symptom → cause → fix. Each fix is independent. |
| Help article — reference | Open-ended | Tables, lists, exhaustive. Skim-first reading model. |
| Release-note item (user-facing) | 1–2 sentences | Say what the user can now do, or what's been fixed. |

If a piece overruns its budget, the cause is almost always one of: too many ideas, hedging, restatement, or scope creep. Cut it.

---

## 5. Topic Types

Every help article is one of four types. Pick before drafting. Mixing types in one article is the most common reason help feels confusing.

### 5.1 Concept

Explains *what something is* and *why it exists in the product*. No steps.

- Use when introducing a noun the user hasn't met (Earmarks, Scheduled Transactions, Splits, Recurring Templates).
- Lead with a one-sentence definition.
- Follow with how it relates to other things they already know.
- End with a link to the most relevant task ("To create one, see …").

### 5.2 Task

Walks through *how to do one thing*. The most common type. Most help requests are task requests.

- Title is `<Verb> <object>`: "Add a transaction", "Split a transaction", "Set up iCloud sync".
- One goal per article. If the article has two goals, it's two articles linked together.
- Numbered steps. Each step is one action.
- End with a Result section confirming what the user should now see.

### 5.3 Reference

Comprehensive, scannable, *look it up* content. Tables, lists, glossaries, keyboard shortcuts.

- No prose padding. The reader is here to find a value, not read.
- Sort alphabetically or by another stable principle. Never by "what's most important" — that's editorialising.

### 5.4 Troubleshooting

Symptom-first content for when something is wrong.

- Title is the symptom, in the user's words: "I can't see my iCloud accounts", not "Resolving iCloud account visibility".
- Lead with the most likely cause and fix.
- Each cause/fix is independent — the user shouldn't have to read top-to-bottom.
- End by telling them what to do if none of it worked (file an issue, contact, etc.).

---

## 6. Article Anatomy

Every help article — whatever its type — follows the same outer shape:

```
# Title (sentence case, action-led for tasks)

A one-sentence intro that says what this article does and who it's for.
Optional second sentence for context. No more.

## (Optional) Before you start
- Prerequisites as a bulleted list. Each item is a precondition the user
  must satisfy, not a teaching moment.

## Body
- Concept: explanation, possibly with one diagram or example.
- Task: numbered steps.
- Reference: tables/lists.
- Troubleshooting: symptom → cause → fix blocks.

## (Tasks only) Result
- One sentence describing what the user should now see.

## (Optional) Next steps / Related
- 2–5 links to adjacent articles. No more.
```

The "Before you start" and "Next steps" sections are optional but useful — include them when they earn their place, drop them when they don't.

### The inverted pyramid

Users scan. Front-load the answer. Put the most important sentence first, the most important word of that sentence early. The reader who stops after one sentence should still get the gist.

> **Don't:** "Moolah supports a variety of account types, including credit cards. To add one, open the sidebar and …"
>
> **Do:** "To add a credit card account, open the sidebar, click **+ Account**, then choose **Credit Card**."

---

## 7. Titles and Headings

### Titles

- **Tasks:** `<Verb> <object>`. "Add a transaction", "Schedule a recurring payment".
- **Concepts:** the noun. "Earmarks", "Categories", "Scheduled transactions".
- **Reference:** "Keyboard shortcuts", "Supported file formats".
- **Troubleshooting:** the symptom, as a user would say it. "Transactions aren't syncing", "I can't find an account I deleted".
- Keep titles under **60 characters**. They have to survive truncation in lists and search.
- No marketing flourishes. No exclamation marks. No emoji.

### Headings

- **Sentence case.** Capitalize the first word and proper nouns only. "Add a recurring transaction" — not "Add A Recurring Transaction".
- No end punctuation. No question marks. (Questions read as headlines, not headings, and they're harder to scan.)
- Front-load the meaningful word: "Sync issues" over "Issues with sync".
- Be parallel within a page. If one H2 is a verb phrase, the rest should be too.
- Don't skip levels. H1 → H2 → H3, not H1 → H3.

---

## 8. Sentences

Target a 9th–10th-grade reading level. Practical rules:

- **Average sentence length: 15 words. Cap: 25.** Anything longer is two sentences in disguise.
- **One idea per sentence.** "And" joining two unrelated thoughts is the most common offender.
- **Active voice.** "Moolah saves the transaction" over "The transaction is saved by Moolah". Passive is fine when the actor is unknown or irrelevant ("The file is encrypted on disk").
- **Present tense.** "The list updates" — not "The list will update" or "The list has been updated". Future tense is acceptable for a result the user has not yet reached: "After you confirm, the transaction appears in the list."
- **Conditions before instructions.** "If you're on a Mac, press ⌘N." Not "Press ⌘N if you're on a Mac." A reader who isn't on a Mac shouldn't have read the keystroke at all.
- **Don't restate the heading** in the first sentence of the section beneath it.

### Contractions

Use them. "It's", "you'll", "you're", "we're", "don't", "can't", "won't" — they're warmer and shorter. Exceptions, where contractions hurt:

- **Negative emphasis.** "Do not delete this file" in an irreversible-action warning, where the strong form is the point.
- **Inside a UI label** that's already in the product without a contraction. Match what the user sees on screen.

---

## 9. Word Choice

### Words to avoid

| Avoid | Reason | Use instead |
|---|---|---|
| just, simply, easily, merely | Presumes the user finds it easy. Often they don't. | Drop the word entirely. |
| please | Servile in instructions; reads as begging. | Drop. "Click **Save**" is more respectful than "Please click **Save**". |
| leverage, utilise, optimise, empower, take control | Corporate speak. Banned by brand guide. | use, make, change, manage |
| robust, seamless, streamline, holistic | Marketing puffery. | Be specific, or cut. |
| simply put, in other words, basically | Filler. If the next sentence is clearer than the previous one, just say the clearer one. | Cut. |
| obviously, of course, clearly | Patronising. If it were obvious, you wouldn't be documenting it. | Cut. |
| see above, see below | Layout-fragile and unscannable. | Link to the section by name. |
| click here, learn more, read more | Useless link text. | "See **Adding a transaction**." |
| sorry, oops, whoops, uh-oh | Twee. Especially in errors — see §13. | Be calm and helpful. |
| feel free to, you may want to | Wishy-washy. | Be direct: "You can …" or just give the instruction. |
| in order to | Padding. | "to" |
| at this point in time, at this time | Padding. | "now" or cut |
| utilise, utilisation | Latinate filler. | "use", "use" |

### Spelling and dialect

Moolah is an Australian product with a global user base. Use **Australian / British English**: *organise, customise, colour, behaviour, recognise*. The brand-guide examples lean American in places — match the product strings, but for net-new help content, prefer the British forms. **Be consistent within a single article.**

Exceptions where the US form is locked in by the product or platform:

- macOS, iOS, iPadOS — official product names.
- iCloud — official product name.
- "Color" / "Behavior" if they appear in an Apple API or system menu the user actually sees.

### Product vocabulary (glossary)

When in doubt, match the term that appears in the product UI. Definitive forms:

| Term | Use it for | Don't say |
|---|---|---|
| Account | A real-world account the user tracks (chequing, savings, credit card, investment, crypto wallet) | "Wallet" for non-crypto accounts |
| Transaction | A single recorded entry in an account | "Entry", "record", "line item" |
| Scheduled transaction | A future-dated, possibly recurring transaction | "Recurring transaction" in isolation — the schedule is the noun |
| Earmark | A user-named bucket of money set aside inside an account | "Envelope", "goal", "savings goal" |
| Category | A user-defined classification on a transaction | "Tag", "label" |
| Split | A transaction divided across multiple categories | "Multi-category transaction" |
| Note | Free-text on a transaction | "Memo", "description" |
| Sync | Optional iCloud sync of data between the user's devices | "Cloud sync", "online sync", "back up" |
| Profile | A self-contained set of accounts and data (for users tracking separate financial worlds) | "Workspace", "vault" |
| Instrument | **Internal-only.** Never user-facing. | If you need to refer to USD/AUD/BTC in copy, say "currency" or "asset". |

Treat this table as authoritative. If you need a term that isn't in it, propose an addition rather than coining one in the article.

### Don't reuse brand-guide marketing phrases as filler

Phrases like *"locked down"*, *"chill vibes"*, *"the boring stuff"* are designed for marketing surfaces (hero copy, landing pages, social). Using them as connective tissue inside a procedural article makes the article feel like an ad. Save them for first-run intros and welcome screens at most.

---

## 10. Referring to UI

### Verbs for interaction

Match the verb to the device, not the surface. If the article is platform-neutral, use **select** or **choose**.

| Verb | When to use |
|---|---|
| **Click** | Mac-only step that requires a pointer (or where the article is Mac-specific). |
| **Tap** | iPhone/iPad step on a touch surface (or where the article is iOS-specific). |
| **Select** | Cross-platform, or when the target can be reached by mouse, touch, **or** keyboard. Default for cross-platform articles. |
| **Choose** | A menu item or option from a list. "Choose **File > Export**." |
| **Press** | A keyboard key or keyboard shortcut. "Press ⌘S." |
| **Drag** | Direct manipulation (dragging a transaction, a file, an account). |
| **Hover** | Mac-only. Never on iOS. |
| **Type / Enter** | Text input. Use "enter" for text the user keys into a field, "type" when the keystrokes matter. |

A cross-platform article should look like this:

> Select the transaction. Then select **Edit > Duplicate**.

Not like this:

> Click (or tap) the transaction. Then click (or tap) **Edit > Duplicate**.

If the steps genuinely diverge across platforms, split into platform-specific sub-sections.

### Naming UI elements

- **Bold the exact label** the user sees on screen, including capitalization: **Add Transaction**, **Categories**, **Done**.
- **Menu paths** use `>` with a single space on each side: "Choose **File > Export > CSV**."
- **Fields** are referred to by their label: "In the **Amount** field, enter …" — not "In the amount box, type …".
- **Keyboard shortcuts** use the symbol form on Mac (`⌘`, `⌥`, `⌃`, `⇧`, `↩`, `⌫`) and the word form on iOS (where shortcuts are rare). Combine with `+` only between letter keys and modifiers when needed for clarity. Examples: "Press ⌘N.", "Press ⌘⇧S to Save As."
- **Never describe a UI element by position** ("the button on the right", "the icon at the top"). Layouts change; labels survive.
- **Never describe a UI element by colour** ("the green button"). Colour alone isn't accessible and changes with appearance modes.
- Refer to **the sidebar** as "the sidebar". Refer to **the inspector** as "the inspector" (it appears on the trailing edge on Mac/iPad). Match `guides/UI_GUIDE.md` §3 for layout language.

### Capitalization of UI labels

Match the product. If the on-screen label is "Add Transaction" with title case, write **Add Transaction**. If it's "Add transaction" with sentence case, write **Add transaction**. Don't normalise.

The exception: a label rendered in `ALL CAPS` (section labels, etc.) becomes sentence case in body copy. "Choose **Accounts** in the sidebar," not "Choose **ACCOUNTS** in the sidebar."

---

## 11. Procedure Structure

A task article's body is a numbered list. Each step is one action.

### Step grammar

- Imperative mood, single action: "Click **Save**.", "Enter the amount."
- Outcome on the same line **only when it isn't obvious**: "Click **Save**. The transaction appears in the list." Drop the second sentence when the outcome is "the dialog closes" or similar uninteresting result.
- Location-first when the user has to navigate to find the control: "In the sidebar, select **Accounts**." Not "Select **Accounts** in the sidebar."
- One step, one verb. Two actions = two steps. The exception is "select X, then Y" inside a menu path, which counts as one.
- Mark non-essential steps with the bracketed marker "(Optional)" or "(Recommended)" at the start.

### Worked example

```
## Add a credit card account

To track a credit card, add it as an account in Moolah.

### Before you start

- Know the card's current balance. You'll enter it as the opening balance.

### Steps

1. In the sidebar, select **+ Account**.
2. Choose **Credit Card**.
3. Enter a name for the account (for example, "Visa — daily").
4. In the **Opening balance** field, enter the current balance owed as a
   negative number (for example, `-450.00`).
5. (Optional) Set an opening date if the balance is from a past statement.
6. Select **Add**.

### Result

The new credit card appears in the sidebar under **Accounts**. Its balance
matches what you entered.
```

Notice what's *not* in there: no "Congratulations!", no "That's it!", no "You're all set!". The result section is descriptive, not celebratory.

---

## 12. Numbers, Currency, Dates

Money software has more locale risk than most. The cost of getting this wrong is a confused user with a real-world finance question — high stakes for trust.

### Numbers

- Spell out zero through nine in prose. Use numerals for 10 and up.
- Numerals always, regardless of size, when the number is a value the user enters, a count of items in a UI, a date component, a version, or anything in a table.
- Use a thin space or comma as a thousands separator depending on locale. In help, **prefer the comma** (`1,234,567`) for English-language content.

### Currency

- **Never assume USD.** Use placeholders like *your currency*, *the account's currency*, or a generic symbol-free amount (`1,234.56`) in examples.
- If you must show a symbol for vividness, use a non-default one to make it visibly an example, and immediately note that it's illustrative: "for example, **€42.00**".
- When the amount has a sign that matters (expense = negative, refund = positive expense, etc.), **show the sign explicitly** and call it out. The brand guide's privacy/precision claim means money copy can't be sloppy here. See `CLAUDE.md` > Monetary Sign Convention.

### Dates and time

- Use the format `Month D, YYYY` for English content: "January 5, 2026."
- In step text where the date format is the user's locale setting, say "today's date" or "the transaction date" rather than committing to a format.
- Don't say "tomorrow", "next week", "recently" — the article outlives the moment it was written. Say "after the date you set" or "on the scheduled day".
- Times are 12-hour with am/pm in English content ("9:30 am"), unless the surface shows 24-hour.

---

## 13. Microcopy Patterns

In-app strings are help content too. They follow all of the above, plus these patterns.

### Error messages

Structure: **what happened → why → what to do.** All three when relevant; cut any that's already obvious.

- **Calm tone.** No exclamation marks. No "Oops!". No "Something went wrong!". The user knows something went wrong — they're the one who hit the error.
- **Don't blame the user.** Banned words: *invalid, illegal, incorrect, error, failure* (as a noun pointed at the user — *"input failure"*).
- **Be specific.** "Couldn't connect to iCloud" beats "Sync failed". "Amount must be a number" beats "Invalid amount".
- **Offer a path forward.** Either a fix the user can perform, or a clear "Try again" / "Cancel" choice. Never a dead-end error with only an OK button unless there's genuinely nothing to do.
- **Preserve the user's input.** Help copy should reinforce this: never tell a user to "start over" if the app can preserve what they typed.

> **Don't:** "Error: Invalid input. Please try again."
>
> **Do:** "Amount must be a number. Check the **Amount** field and try again."

### Empty states

Structure: **what would be here → how to make it appear.** No more.

- Lead with the noun. "No transactions yet." or "No earmarks set up." Not "Welcome to your transactions!"
- One actionable next step, ideally with a button that matches the article's main task.
- Resist filling space with marketing copy. An empty state is a fine place for a single warm sentence, but only one.

> **Don't:** "Looks pretty empty in here! 🦗 Why not add your first transaction and get on the road to financial freedom?"
>
> **Do:** "No transactions yet. **Add Transaction** to get started."

### Tooltips and field hints

- **One sentence. ≤ 12 words for tooltips, ≤ 20 for hints.**
- Don't restate the label. The tooltip for **Sync** isn't "Sync your data".
- Hints describe the format expected, the consequence of changing the value, or the relationship to a nearby field — not the obvious meaning of the label.

> **Don't (tooltip on a "Mark as cleared" toggle):** "Mark this transaction as cleared."
>
> **Do:** "Cleared transactions count toward your reconciled balance."

### Confirmations and destructive actions

- **Title states the action and its scope.** "Delete this account?" not "Are you sure?"
- **Body states what will happen and what won't.** Be specific about side effects: deleting an account also deletes its transactions; that has to be in the body.
- **Buttons are verbs, not "Yes/No".** "Delete account" / "Cancel". The destructive button uses the destructive style; never make Cancel the prominent one.
- **Don't soften destructive language.** "Delete" means delete. Don't say "remove" if the data is gone.

### Onboarding

- Match the brand-guide onboarding tone: warm, encouraging, low-friction.
- One idea per step. Make every step skippable unless skipping breaks the next one.
- Don't teach finance. Don't lecture about good habits. The onboarding's job is to get the user from install to a usable state, not to explain why budgeting is good.

---

## 14. Privacy Claims

Privacy is a brand pillar (§11, brand guide). Help content's privacy claims have to be **literally true**.

- The app uses **manual entry** only. Never write "Moolah connects to your bank", "imports automatically", "syncs with your accounts", etc. Even casually.
- Data lives **on the user's device** and **in their own iCloud** (when sync is enabled). It does not travel through Moolah servers, because there are no Moolah servers. Help copy must reflect this without overstating: don't say "we never see your data" — there is no "we" in the data path, that's the point.
- **iCloud sync is opt-in and end-to-end encrypted by iCloud.** Don't add qualifiers ("relatively secure", "best-effort"). Don't omit "optional".
- Don't invent privacy features. The brand guide's `Product Facts` (§10) is the floor.
- When in doubt, use approved phrasing from the brand guide §11:
  - "Your data lives on your device."
  - "No accounts, no cloud servers, no one looking over your shoulder."
  - "Private. Like, actually private."

---

## 15. Accessibility and Inclusion

Help is a substitute for sight, hearing, dexterity, and memory. Build it to work for all of those.

### Plain-language and reading level

- Sentence length cap: 25 words. Average around 15.
- Word length: prefer short words. *Use* over *utilise*, *help* over *assistance*, *now* over *currently*.
- One topic per article. One idea per sentence.

### Structure for screen readers

- Always use heading markup (H1, H2, H3) for hierarchy. Never use bold-as-heading.
- Lists use list markup, not paragraphs separated by line breaks.
- Tables have headers in the first row; never use a table for non-tabular layout.

### Link text

- Link text describes the destination. "See **Adding a transaction**." Not "Click here." Not "More info."
- Don't put a link inside another visually-identical link.

### Images

- Every image has alt text describing **what the user would learn from it**, not what's literally pictured. Alt for a screenshot of the sidebar isn't "Screenshot of the Moolah sidebar"; it's "The sidebar with the Accounts section expanded, showing three example accounts."
- Don't put information in an image that isn't repeated in surrounding text.
- If an image illustrates a step, the step's text must still work without the image.

### Inclusive language

- Use the singular "they" when the gender of a hypothetical user is irrelevant or unknown. Don't alternate he/she.
- No idioms or culture-specific references that don't translate: *"kill two birds", "no-brainer", "ballpark"*. Help is consumed globally and often by translators.
- Avoid metaphors built on disability, violence, or finance-shaming language. The brand voice's "no preachy" extends to "no shame".

### Colour

- Never describe a UI element only by colour ("the red button"). Pair it with the label or shape.
- Income/expense colour conventions exist (blue/green for income, red for expenses, gold for balance) — referencing them is fine, but never as the sole identifier.

---

## 16. Images, Screenshots, and Diagrams

Use them sparingly. Screenshots go stale the moment the UI ships its next change, and a stale screenshot is worse than no screenshot.

When you do use one:

- It must add information the text can't economically convey (layout, spatial relationships, before/after states).
- Crop tight. Don't show the whole window when the relevant element is a single field.
- Use the default macOS or iOS appearance modes. Match the brand-guide colour story but never recolour Apple controls.
- Annotate sparingly, with labels in the brand's typography or the system equivalent. Never use red arrows scribbled across the image; use a clean callout with the brand's Income Blue (`#1E64EE`) or system tint.
- Provide @1x and @2x variants for raster screenshots; or SVG for diagrams.
- The image file name follows the article slug: `add-credit-card-step-3.png`.
- The image gets alt text — see §15.

Diagrams are different from screenshots: they don't go stale as fast. Prefer a diagram over a screenshot when the topic is conceptual (data model, sync flow).

---

## 17. Cross-Linking

- Link to the most useful next step from a task. Most useful = what a user is most likely to need to do next, not what's most adjacent in the table of contents.
- Limit each article to about **5 cross-links in the body**. More than that and the article is failing to stand on its own.
- The "Related" or "Next steps" section at the end can have a few more, but cap around 5 there too.
- Link text is the title of the destination. "See **Schedule a recurring transaction**." Not "Read about scheduling here."
- Don't link the same destination more than once per page. The first mention gets the link.
- Don't link the *current* article from inside itself.

---

## 18. Maintenance

Help content has the half-life of a fresh banana. Plan for it.

- Every article has an owner field and a last-reviewed date (publishing system handles the metadata; the writing has to make review feasible).
- When a feature ships, all affected help is updated **in the same PR** as the feature, not in a follow-up. The release isn't done until the help is.
- When a feature is removed, all references to it are removed. Search the help corpus before merging the removal.
- Don't reference unreleased features. Don't reference "coming soon". If it's not in the shipped app, it doesn't exist in the help.
- Don't include version numbers in body copy unless the article is specifically about version-specific behaviour. Versions appear in release notes, not in "Add a transaction".
- Don't reference OS versions below the supported floor (macOS 26, iOS 26). When the floor rises, scrub references that no longer apply.

---

## 19. Pre-Publish Checklist

Run through this before publishing or merging a help change. Treat it as a hard checklist, not a vibe check.

- [ ] **Topic type is clear.** The article is exactly one of: concept, task, reference, troubleshooting. Not a mix.
- [ ] **Title matches type.** Verb-led for tasks, noun for concepts, symptom-led for troubleshooting.
- [ ] **One-sentence intro answers "what is this article?"**
- [ ] **Inverted pyramid.** The most important sentence is the first sentence of the body, not the last paragraph.
- [ ] **Brand voice present, marketing voice absent.** Reads like Moolah; doesn't read like a landing page.
- [ ] **Plain-spoken.** No leverage/utilise/empower/streamline/robust/seamless/please.
- [ ] **Reading level.** Sentences average ~15 words, none over 25. No paragraph over five sentences.
- [ ] **Contractions where natural.** Not in destructive warnings or trademarked names.
- [ ] **Active voice unless passive is genuinely better.**
- [ ] **Present tense unless describing a future result.**
- [ ] **No banned words from §9.**
- [ ] **Product vocabulary matches §9 glossary.**
- [ ] **UI labels are bolded and match the on-screen text exactly.**
- [ ] **Menu paths use `>` with single spaces.**
- [ ] **Interaction verb matches the platform** (tap/click/select/choose as appropriate per §10).
- [ ] **No UI element described only by position or colour.**
- [ ] **Steps are imperative, single-action, location-first when navigating.**
- [ ] **A task article has a Result section.**
- [ ] **No assumed currency, no assumed locale, no idioms, no scolding.**
- [ ] **Privacy claims are literally true and match brand guide §10 and §11.**
- [ ] **No promises of features the app doesn't have** (no bank sync, no automatic categorisation, no AI features that aren't shipped).
- [ ] **No "coming soon", no version numbers in body, no references to retired features.**
- [ ] **Cross-links use descriptive text** (never "click here", "learn more").
- [ ] **Cross-links cap around 5 in the body, 5 in Related.**
- [ ] **Images add information that text can't.** Alt text describes the takeaway, not the picture.
- [ ] **Headings are sentence case, no end punctuation, parallel in form.**
- [ ] **No emoji, no exclamation marks outside legitimate alerts, no twee microcopy.**
- [ ] **Read it aloud.** If you stumble, the reader will too.

If any item fails, fix it before the help change merges — same rule as code.

---

## 20. References

- `guides/BRAND_GUIDE.md` — voice, vocabulary, approved copy. Authoritative.
- `guides/UI_GUIDE.md` — layout language, the names of structural UI elements (sidebar, inspector, detail), HIG alignment.
- `CLAUDE.md` — product facts that bound what's true about the app (manual entry, no servers, sign convention, supported OS floor).
- Apple HIG — *Writing*. https://developer.apple.com/design/human-interface-guidelines/writing
- Apple Style Guide. https://support.apple.com/guide/applestyleguide/
- Google developer documentation style guide. https://developers.google.com/style
- Microsoft Writing Style Guide. https://learn.microsoft.com/en-us/style-guide/welcome/
- GOV.UK content design — Writing for GOV.UK. https://www.gov.uk/guidance/content-design/writing-for-gov-uk
- NN/g — Error message guidelines. https://www.nngroup.com/articles/error-message-guidelines/
- NN/g — Microcontent. https://www.nngroup.com/articles/microcontent-how-to-write-headlines-page-titles-and-subject-lines/

When this guide and any external reference conflict, this guide wins. When this guide and the brand guide conflict, the brand guide wins.
