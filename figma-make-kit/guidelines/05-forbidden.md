# Forbidden — instant "AI-generated" tells

Generating ANY of these is a defect:

1. **Tailwind utility classes** (`p-4`, `bg-gray-100`, `flex gap-2`) or shadcn/ui components —
   this project uses Fluent v9 + Griffel exclusively.
2. **Hex codes / named colors / raw px** anywhere — tokens only.
3. **Boolean prop variants** — `<Button primary>` is wrong; `<Button appearance="primary">` is right.
4. **Hand-rolled versions of Fluent primitives** — custom tables, custom modals, custom dropdowns,
   div-built cards, imported SVGs for icons Fluent ships.
5. **Centered full-page spinner** as the only loading state; **empty tables with just headers**.
6. **Multiple primary buttons** per view; red danger buttons instead of confirmation dialogs.
7. **`useEffect` data fetching** — TanStack Query v5 only. Forms without React Hook Form + Zod.
8. **`outline: none`**, missing `aria-label` on icon buttons, `tabIndex > 0`.
9. **Equal-weight layouts** — no hierarchy, every card the same size, every text the same gray.
10. **Decorative animation** — motion without a cause-effect meaning, or missing motion tokens.
