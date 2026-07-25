# Design System Specification: The Digital Archive

## 1. Overview & Creative North Star

**Creative North Star: "The Digital Curator"**

This design system is built to bridge the gap between the tactile weight of a 19th-century ledger and the hyper-efficiency of modern data science. We are not building a standard "SaaS dashboard"; we are crafting a digital repository of record.

To achieve this, the system moves away from the "boxy" nature of the web. We use **Intentional Asymmetry** and **Tonal Depth** to guide the eye. By breaking the rigid 12-column grid with staggered elements and varying typographic scales, we create a layout that feels like a bespoke broadsheet newspaper—authoritative, curated, and timeless. The goal is to make the user feel they are consulting a definitive source of truth.

---

## 2. Colors: Tonal Integrity & The "No-Line" Rule

Our palette is rooted in British heritage—heavy Navy and warm Cream. However, the sophistication lies in how these shades are layered.

### The "No-Line" Rule

**Explicit Instruction:** Traditional 1px solid borders are strictly prohibited for sectioning content. Boundaries must be defined through **Background Color Shifts**. To separate a sidebar from a main feed, transition from `surface` to `surface-container-low`. This creates a seamless, high-end feel that avoids the "cheap" look of boxed templates.

### Surface Hierarchy & Nesting

Treat the UI as a physical stack of fine parchment. Use the surface-container tiers to define importance:

- **Base Layer:** `surface` (#fcf9f4) for the main canvas.
- **Content Areas:** `surface-container-low` (#f6f3ee) for secondary information.
- **Focus Elements:** `surface-container-lowest` (#ffffff) for primary cards or data tables to provide "pop" against the cream background.

### Signature Textures

- **The Navy Gradient:** For hero sections or primary CTAs, do not use flat #002147. Instead, use a subtle linear gradient transitioning from `primary` (#000a1e) to `primary_container` (#002147). This adds a "visual soul" reminiscent of deep ink on paper.
- **Glassmorphism:** For floating navigation or tooltips, use `surface` with 80% opacity and a `20px` backdrop-blur. This ensures the "Archive" stays integrated and doesn't feel disconnected from the data beneath it.

---

## 3. Typography: The Editorial Voice

We pair the intellectual elegance of **Newsreader** with the functional clarity of **Work Sans**.

- **Newsreader (Display & Headline):** Use this for all high-level storytelling and data headers. It carries the weight of a traditional UK broadsheet. Use tight letter-spacing (-0.02em) for large displays to increase authority.
- **Work Sans (Title & Body):** Optimized for legibility in dense data environments. Use `title-md` for data labels to ensure they remain "invisible" yet highly functional, allowing the headlines to shine.

**Hierarchy Strategy:**

- **Display-lg (3.5rem):** Reserved for major landing page statements.
- **Headline-md (1.75rem):** The standard for individual company names in records.
- **Body-md (0.875rem):** The workhorse for all business descriptions and financial data.

---

## 4. Elevation & Depth: Tonal Layering

In "The Digital Archive," depth is perceived, not forced.

- **The Layering Principle:** Place a `surface-container-lowest` card onto a `surface-container-low` section. The slight shift in brightness creates a "Soft Lift."
- **Ambient Shadows:** If a card must float (e.g., a modal or dropdown), use a shadow tinted with the `on-surface` color: `box-shadow: 0 12px 32px rgba(28, 28, 25, 0.06);`. This mimics natural light falling on paper.
- **The Ghost Border Fallback:** If accessibility requires a border, use the `outline-variant` token at **15% opacity**. A 100% opaque border is a failure of the design system's elegance.

---

## 5. Components: Functional Elegance

### Buttons

- **Primary:** Background: `primary_container`; Text: `on_primary`. Roundedness: none (0rem). A sharp corner
  communicates precision and traditionalism.
- **Tertiary:** No background or border. Text: `primary`. Use for "Cancel" or "Secondary" actions, styled as a modern underline (2px offset).

### Data Cards & Lists

- **The "No-Divider" Rule:** Never use horizontal lines to separate list items. Use **Vertical White Space** (1.5rem to 2rem) or alternating background shifts (`surface` to `surface-container-low`) to create distinction.
- **Typography Lead:** Use `headline-sm` (Newsreader) for the primary data point (e.g., Company Name) and `label-md` (Work Sans) for the metadata (e.g., CRN Number).

### Input Fields

- **Style:** Minimalist. Only a bottom border (2px) using `outline-variant`. Upon focus, the border transitions to `primary_container`.
- **Background:** Always `surface_container_lowest` to signal interactivity against the cream background.

### Signature Component: The "Archive Ledger"

A specialized data table for financial histories.

- **Header:** `primary_container` background with `on_primary` text in `label-sm` (all caps, 0.05em tracking).
- **Cells:** `surface` background with `body-md` text. No vertical lines; only subtle horizontal shifts on hover.

---

## 6. Do’s and Don’ts

### Do

- **Do** use British English spelling (e.g., "Catalogue," "Organisations," "Centres").
- **Do** embrace generous white space. An authoritative document is never "cramped."
- **Do** use Newsreader for numbers in financial contexts to evoke the feeling of a hand-inked ledger.

### Don't

- **Don't** use `9999px` (full) roundedness. It is too "playful." Stick to `none` for a structured, professional look.
- **Don't** use pure black (#000000). Use `primary` (#000a1e) for all dark elements to maintain the navy tonal theme.
- **Don't** use standard "Blue" for links. Use `primary` with a sophisticated underline or a subtle weight increase.
- **Don't** overuse the dark navy `primary-container` as a background, especially on large elements.

---

## 7. Accessibility & Readability

- **Contrast:** Ensure all `on_surface` text on `surface` backgrounds maintains a minimum 7:1 contrast ratio to accommodate users consulting the archive in various lighting conditions.
- **Scale:** Never drop below `body-sm` (0.75rem) for legal or archival fine print. Professionalism requires transparency, not hidden text.
