# Design system: ch-fixedwidth converter

## 1. Overview & creative north star

**Creative north star: "The bulk converter"**

This design system styles the **ch-fixedwidth** browser and related surfaces as a precise data conversion tool — not a SaaS dashboard and not a document archive. Users drop Companies House fixed-width bulk files and leave with clean CSV. Authority comes from clarity, speed cues, and trustworthy British heritage colour — not from ledger metaphor or newspaper layout.

The goal is to make conversion feel local, private, and reliable: a workshop tool for bulk data, not a curated museum of company records.

---

## 2. Colours: tonal integrity & the "no-line" rule

Palette is rooted in British heritage — heavy navy and warm cream — layered for depth without chrome.

### The "no-line" rule

**Explicit instruction:** Traditional 1px solid borders are strictly prohibited for sectioning content. Boundaries must be defined through **background colour shifts**. To separate a control strip from the main column, transition from `surface` to `surface-container-low`. This avoids the cheap look of boxed templates.

### Surface hierarchy & nesting

Treat the UI as stacked work surfaces:

- **Base layer:** `surface` (#fcf9f4) for the main canvas.
- **Secondary areas:** `surface-container-low` (#f6f3ee) for supporting copy and tips.
- **Focus elements:** `surface-container-lowest` (#ffffff) for primary panels (input, convert) so they pop against cream.

### Signature textures

- **The navy gradient:** For primary CTAs, do not use flat #002147. Use a subtle linear gradient from `primary` (#000a1e) to `primary_container` (#002147).
- **Glassmorphism:** For floating tooltips only: `surface` at 80% opacity with a `20px` backdrop-blur.

---

## 3. Typography: clear converter voice

Pair **Newsreader** (display / page titles) with **Work Sans** (UI, labels, dense meta).

- **Newsreader:** Page title and major headings — weight without shouting.
- **Work Sans:** Buttons, file names, progress, status, footer — optimized for dense UI.

**Hierarchy:**

- **Display-lg (3.5rem):** Rare; landing statements only if needed.
- **Headline-md (1.75rem):** Primary page title (e.g. "Companies House bulk converter").
- **Body-md (0.875rem):** Status, tips, and secondary copy.

---

## 4. Elevation & depth: tonal layering

Depth is perceived, not forced.

- **The layering principle:** Place a `surface-container-lowest` panel on `surface` or `surface-container-low`. Slight brightness shift creates a soft lift.
- **Ambient shadows:** If a control must float (modal/dropdown), use `box-shadow: 0 12px 32px rgba(28, 28, 25, 0.06);`.
- **Ghost border fallback:** If accessibility requires a border, use `outline-variant` at **15% opacity**. A 100% opaque border is a failure of the system’s elegance.

---

## 5. Components: functional elegance

### Buttons

- **Primary:** Background `primary_container`; text `on_primary`. Roundedness: none (0rem). Sharp corners communicate precision.
- **Tertiary:** No background or border. Text `primary`. Use for Cancel; underline at 2px offset.

### Lists & queues

- **No-divider rule:** Never use horizontal lines between list items. Use vertical white space (1.5rem–2rem) or alternating surface shifts.
- **Typography lead:** File name in stronger Work Sans or small Newsreader; size/status as `label-md` / `body-sm` meta.

### Input fields

- **Style:** Minimalist. Bottom border only (2px) using `outline-variant`. Focus → `primary_container`.
- **Background:** `surface_container_lowest` against cream.

### Progress & results

- Progress rails and bars use navy/cream tonal contrast, not bright “SaaS blue”.
- Status copy is British English, plain, and task-focused (“Writing CSV…”, “Batch complete”).

---

## 6. Do’s and don’ts

### Do

- **Do** use British English spelling (e.g. "Organisations", "Centres" when those words appear).
- **Do** embrace generous white space — a conversion tool should not feel cramped.
- **Do** name the product **ch-fixedwidth** (or sentence-case “Companies House bulk converter” for the page title).
- **Do** describe multi-product capability when listing supported inputs.

### Don't

- **Don't** use full pill roundedness (`9999px`). Stick to `none` for a structured, professional look.
- **Don't** use pure black (#000000). Use `primary` (#000a1e) for dark elements.
- **Don't** use standard “link blue”. Use `primary` with underline or weight increase.
- **Don't** frame the UI as a digital archive, ledger, or newspaper — it is a **converter**.
