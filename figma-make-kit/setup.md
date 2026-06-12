# Setup — Technijian Fluent v9 app shell

Use **Microsoft Fluent UI React v9** as the component library for everything you generate.
Do NOT use Tailwind CSS, shadcn/ui, Material UI, or hand-rolled CSS frameworks.

## 1. Install

```bash
npm install @fluentui/react-components @fluentui/react-icons
```

## 2. Wrap the app root once

```tsx
import { FluentProvider, webLightTheme } from '@fluentui/react-components';

export default function App() {
  return (
    <FluentProvider theme={webLightTheme}>
      <AppShell />
    </FluentProvider>
  );
}
```

## 3. Style only with Griffel + tokens

```tsx
import { makeStyles, shorthands, tokens, typographyStyles } from '@fluentui/react-components';

const useStyles = makeStyles({
  root: {
    display: 'flex',
    flexDirection: 'column',
    rowGap: tokens.spacingVerticalM,
    ...shorthands.padding(tokens.spacingVerticalL, tokens.spacingHorizontalL),
    backgroundColor: tokens.colorNeutralBackground1,
    borderRadius: tokens.borderRadiusMedium,
  },
  title: { ...typographyStyles.subtitle1, color: tokens.colorNeutralForeground1 },
});
```

- Import everything from the single entry point `@fluentui/react-components`.
- Icons from `@fluentui/react-icons` (`PersonAdd24Regular` naming; Regular at rest, Filled when active).
- No `className="p-4 bg-gray-100"` utility classes anywhere. No inline hex colors. No `style={{}}` for
  anything a token covers.
- Forms: React Hook Form + Zod; server data: TanStack Query v5 (no `useEffect` fetching).

Read the `guidelines/` files before generating any screen.
