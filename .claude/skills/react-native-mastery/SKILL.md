---
name: react-native-mastery
description:
  Production-grade React Native + Expo mobile design and implementation
  discipline for iOS and Android from a single codebase. Activates whenever
  the user requests mobile app work, React Native components, screens,
  navigation, or any mobile frontend implementation. Output must feel native
  on both platforms — not like a web page in a WebView, not like a
  cross-platform app that betrays its cross-platform nature. Backend is the
  same .NET 8/9 + SQL Server + Swagger API used by web.
metadata:
  stack: "React Native + Expo SDK 50+, TypeScript strict, React Navigation v6+, TanStack Query v5, React Hook Form + Zod, Reanimated v3, FlashList, expo-image, expo-haptics"
  related-skills: [react-native-design-review, fluent-v9-mastery, react-ui-design-patterns]
  version: '1.0.0'
  applies-to: mobile-code-generation, ios-android-ui, mobile-feature-implementation
  platforms: [ios, android]
---

# React Native Mobile Design & Implementation Mastery

You are designing and building a production-grade, professionally designed
mobile app using React Native with Expo, targeting both iOS and Android
from a single codebase. The backend is the same .NET 8/9 + SQL Server +
Swagger API used by our web frontend. Your output must feel native on both
platforms — not like a web page in a WebView, not like a cross-platform
app that betrays its cross-platform nature.

Internalize everything below before writing a single line of code. Mobile
is not responsive web. It has its own rules, and violating them produces
apps that users delete.

## Part 1 — The Core Tension: One Codebase, Two Platforms

Your single hardest job is knowing when to unify and when to diverge.

**Unify** (one implementation for both platforms):

- Business logic, data fetching, state management
- Brand identity: colors, typography scale, iconography, imagery
- Layout structure, information architecture, screen flow
- Form patterns, validation, error handling
- Most components (buttons, cards, lists, inputs)

**Diverge** (platform-specific behavior):

- Navigation chrome (headers, back behavior, tab bar position)
- System fonts (San Francisco on iOS, Roboto on Android)
- Haptic feedback patterns (iOS uses richer haptics than Android)
- Native gestures (iOS swipe-back, Android predictive back)
- Modal presentation (iOS sheets with detents, Android bottom sheets)
- Platform icons where system conventions differ (share icon, back chevron)
- Status bar behavior
- Safe area handling (notch, home indicator, camera cutout)
- Keyboard behavior and accessory views
- Date/time pickers (native per platform)
- Alert and action sheet styling

**The rule:** diverge only when the platform convention is strong and
violating it would feel wrong to a native user of that platform.
Otherwise, unify.

Use `Platform.OS`, `Platform.select()`, and `.ios.tsx` / `.android.tsx`
file extensions for divergence. Keep divergent code narrow and colocated
with the component, never sprawling across the codebase.

## Part 2 — Stack & Tooling

**Framework:** React Native via Expo (managed workflow unless bare is
explicitly justified). Expo SDK 50+.

**Language:** TypeScript strict mode. No `any`. No `@ts-ignore` without
a comment.

**Navigation:** React Navigation v6+. Use the right navigator for the
job — Native Stack for hierarchy, Bottom Tabs for top-level sections,
Drawer only for apps with >5 top-level sections or deep secondary
navigation.

**Styling:** Choose one system and stick to it across the app:

- **Tamagui** (recommended for design-system-heavy apps — compile-time
  optimization, built-in tokens, excellent DX)
- **Restyle** (Shopify's system — great for strict token discipline)
- **NativeWind** (Tailwind for RN — familiar but less mobile-native feel)
- **StyleSheet.create + a tokens module** (simplest, zero dependencies)

This skill uses `StyleSheet.create + tokens module` as the baseline
because it's universal. Substitute patterns where your chosen system
differs, but the principles remain identical.

**Animation:** `react-native-reanimated` v3+ for anything beyond trivial
opacity/transform. `react-native-gesture-handler` for gestures. Never
use the deprecated `Animated` API for new code.

**Data:** TanStack Query v5 for server state. React Hook Form + Zod for
forms. Generated Swagger client in `src/api/generated/` — same pattern
as web.

**Icons:** `@expo/vector-icons` (wraps multiple icon sets) or
platform-appropriate sets: SF Symbols via `sf-symbols-ios` on iOS,
Material Symbols via `react-native-vector-icons/MaterialIcons` on
Android. For cross-platform unity, Lucide via `lucide-react-native` is
the pragmatic choice.

**Images:** `expo-image` (not the built-in `Image`) for caching,
transitions, and format support.

**Lists:** `@shopify/flash-list` for any list with >20 items or variable
row heights. `FlatList` for simple fixed-height lists. Never `ScrollView`
with `.map()` for dynamic data.

**Storage:** `expo-secure-store` for tokens/credentials.
`@react-native-async-storage/async-storage` for non-sensitive
persistence. `expo-sqlite` for offline data.

**Forms of critical infra:** `expo-haptics` (haptic feedback),
`expo-blur` (native blur effects), `expo-linear-gradient`,
`react-native-safe-area-context` (safe area insets),
`react-native-screens` (enabled by default in Expo).

## Part 3 — Design Tokens (The Foundation)

Define tokens once in `src/theme/tokens.ts`. Every style value in the app
references them. No raw pixel numbers, no hex codes anywhere except this
file.

```ts
export const tokens = {
  color: {
    background: { primary: '...', secondary: '...', tertiary: '...', elevated: '...' },
    text: { primary: '...', secondary: '...', tertiary: '...', disabled: '...', inverse: '...' },
    brand: { 50: '...', 100: '...', /* ... */ 900: '...' },
    border: { subtle: '...', default: '...', strong: '...' },
    status: { success: '...', warning: '...', danger: '...', info: '...' },
  },
  space: { xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32, xxxl: 48 },
  radius: { none: 0, sm: 4, md: 8, lg: 12, xl: 16, full: 9999 },
  font: {
    family: {
      regular: Platform.select({ ios: 'System', android: 'Roboto' }),
      medium: Platform.select({ ios: 'System', android: 'Roboto_medium' }),
    },
    size: { xs: 11, sm: 13, base: 15, md: 17, lg: 20, xl: 24, xxl: 30, display: 36 },
    weight: { regular: '400', medium: '500', semibold: '600', bold: '700' },
    lineHeight: { tight: 1.2, normal: 1.4, relaxed: 1.6 },
  },
  shadow: {
    sm: Platform.select({
      ios: { shadowOpacity: 0.05, shadowRadius: 2, shadowOffset: { width: 0, height: 1 } },
      android: { elevation: 1 },
    }),
    md: Platform.select({
      ios: { shadowOpacity: 0.1, shadowRadius: 8, shadowOffset: { width: 0, height: 2 } },
      android: { elevation: 3 },
    }),
    lg: Platform.select({
      ios: { shadowOpacity: 0.15, shadowRadius: 16, shadowOffset: { width: 0, height: 4 } },
      android: { elevation: 8 },
    }),
  },
  motion: {
    duration: { instant: 100, fast: 200, normal: 300, slow: 450 },
    easing: { /* reanimated easings */ },
  },
  touch: { minTarget: 44 },
};
```

Build a `useTheme()` hook that returns tokens (so you can swap light/dark
without prop drilling):

```ts
const theme = useTheme();
```

Detect color scheme via `useColorScheme()` from React Native. Respect
user preference by default; offer override in settings.

## Part 4 — Typography Rules

Mobile typography is not web typography. Rules:

- **System fonts by default.** San Francisco (iOS) and Roboto (Android)
  are optimized for their platforms. Custom fonts only for brand
  headlines.
- **Honor Dynamic Type (iOS) and Font Scale (Android).** Users with
  accessibility needs resize system text. Your UI must adapt. Use
  `allowFontScaling` (default true) and design layouts that survive
  130%+ scaling.
- **Line height is non-optional.** Tight text is illegible on small
  screens. Minimum 1.3 for body, 1.2 for headings.
- **Letter spacing on small caps and all-caps labels** (`letterSpacing: 0.5`).
  Never on body text.
- **Text hierarchy via size + weight, not via color alone.** Secondary
  text uses `text.secondary` plus smaller size.
- **Max ~60 characters per line on phones.** On large phones and
  tablets, cap content width.
- **Right-align numbers in tables. Left-align text. Always.**

Typography component pattern:

```tsx
<Text variant="body" color="secondary">...</Text>
<Text variant="heading2">...</Text>
<Text variant="caption" numberOfLines={1}>...</Text>
```

Build a single `<Text>` wrapper with `variant` prop that maps to
`tokens.font` — never use bare `<Text>` with inline size/weight in
screens.

## Part 5 — Layout & Safe Areas

Mobile screens have hostile edges: notches, home indicators, status
bars, camera cutouts, navigation bars, keyboards.

**Always wrap screens** in `SafeAreaView` from
`react-native-safe-area-context` (not the one from `react-native` —
that's deprecated and iOS-only). Use `edges` prop to control which
insets apply:

```tsx
<SafeAreaView edges={['top', 'left', 'right']} style={{ flex: 1 }}>
  {/* bottom inset handled by tab bar */}
</SafeAreaView>
```

**`KeyboardAvoidingView`** on every screen with text input. Use
`behavior="padding"` on iOS, `behavior="height"` on Android. Wrap the
whole screen, not individual inputs.

**Screen structure pattern:**

```text
SafeAreaView
├── Header (sticky, platform-appropriate)
├── ScrollView / FlashList (main content, flex: 1)
│   └── Content sections with consistent spacing
└── Footer / primary action (sticky, above tab bar or home indicator)
```

**Spacing rhythm:**

- Screen horizontal padding: `space.lg` (16px) on phones, `space.xl`
  (24px) on tablets
- Between sections: `space.xl` (24px)
- Within a section: `space.md` (12px)
- Inside cards: `space.lg` (16px)

**Content max-width on tablets:** cap at 640px and center. Full-bleed
layouts on phones look lost on tablets.

**One-handed reach.** Primary actions live in the bottom third of the
screen where thumbs reach. Never put a primary button at the top of a
long scrolling form — float it at the bottom.

## Part 6 — Navigation (The Backbone)

React Navigation is the default. Use the right navigator per job:

**Native Stack Navigator** (`@react-navigation/native-stack`) for
hierarchical flows. It uses native platform transitions (slide on iOS,
fade-up on Android) and integrates with `react-native-screens` for
performance. Always prefer this over JS Stack unless you need heavy
customization of transitions.

**Bottom Tab Navigator** for 2–5 top-level sections. Never more than 5
tabs. Tab icons use `tabBarIcon`; labels are short nouns.

**Drawer Navigator** only when you have >5 top-level destinations or a
clear primary/secondary nav split. Drawers are an anti-pattern for
discoverability — avoid when possible.

**Modal presentation** for focused tasks (creating/editing an entity,
multi-step forms, confirmations that need more than an `Alert`). Use
`presentation: 'modal'` on iOS (native sheet),
`presentation: 'transparentModal'` with custom styling on Android.

**Header patterns:**

- iOS: title centered or large (scrolling-collapse large title), back
  button shows previous screen's title
- Android: title left-aligned, back arrow only, no previous title
- Use `headerLargeTitle: true` on iOS list screens for the collapse effect
- Right action buttons: `headerRight` with a `TouchableOpacity` wrapped
  icon/text

**Back behavior:**

- iOS: swipe-from-left-edge gesture enabled by default
  (`gestureEnabled: true`)
- Android: hardware/gesture back handled automatically by React Navigation
- For forms with unsaved changes, intercept with `beforeRemove` listener
  and show confirmation

**Deep linking:** Configure `linking` prop on `NavigationContainer` so
every screen has a URL. Universal links (iOS) and App Links (Android)
route to the right screen.

## Part 7 — Component Patterns

Build a core component library in `src/components/` used across all
features. Never compose screens from bare `View` + `Text` + `Pressable`.

**Core components to build first:**

- **Button** — variants: primary, secondary, tertiary, ghost,
  destructive. Sizes: sm, md, lg. Always uses `Pressable` with
  `android_ripple` for Android tap feedback and `pressRetentionOffset`
  for iOS. Minimum 44×44 touch target. Haptic feedback on press
  (`expo-haptics`) for primary actions. Disabled state has reduced
  opacity and no ripple.
- **IconButton** — icon-only button with required `accessibilityLabel`.
  Same touch target minimum. Used in headers and toolbars.
- **Text** — variant-driven wrapper (see Part 4).
- **Input** — wraps `TextInput` with label, helper text, error state,
  and icon slots. Styled border state changes on focus. Uses
  `autoCapitalize`, `autoCorrect`, `keyboardType`, `textContentType`
  (iOS autofill), `autoComplete` (Android autofill) correctly per field
  type. Password fields have show/hide toggle.
- **Select / Picker** — platform-appropriate: iOS uses a bottom sheet or
  inline wheel picker, Android uses a bottom sheet menu. Never use the
  built-in `Picker` — it's ugly on both platforms.
- **Switch** — uses native `Switch` from React Native (already
  platform-adaptive). Pair with a label row.
- **Checkbox** — build with `Pressable` + icon. Native checkboxes don't
  exist in RN.
- **RadioGroup** — same as Checkbox pattern, with single-selection
  logic.
- **Card** — surface component with elevation token, padding, optional
  header/footer. `Pressable` variant for tappable cards.
- **ListItem** — standardized row with leading icon/avatar, title,
  subtitle, trailing chevron/action. The workhorse of mobile UIs.
- **Avatar** — circular image with initials fallback. Sizes: xs, sm, md,
  lg, xl.
- **Badge** — small pill for counts or status. Variants match status
  colors.
- **Chip / Tag** — filter chip, input chip (with remove), choice chip.
- **BottomSheet** — use `@gorhom/bottom-sheet` (the de facto standard).
  For simple sheets, use React Navigation modal with
  `presentation: 'modal'` on iOS.
- **Alert** — use native `Alert.alert()` for true system alerts. For
  richer content, use a `BottomSheet` or modal screen.
- **Toast / Snackbar** — use `sonner-native` or
  `react-native-toast-message`. Position top on iOS, bottom on Android
  (platform convention).
- **Skeleton** — animated loading placeholder matching final content
  shape. Use `react-native-reanimated` for the shimmer.
- **EmptyState** — illustration or icon + headline + supporting text +
  primary action.
- **ErrorState** — similar to empty state but with retry action and
  error-tinted icon.

## Part 8 — Lists (Where Performance Dies)

Lists are the most common performance trap in RN. Rules:

For any list that can grow beyond ~20 items or has variable row
heights, use `FlashList` from `@shopify/flash-list`. It's 10× more
performant than `FlatList` on long lists.

```tsx
<FlashList
  data={items}
  renderItem={({ item }) => <ListItem {...item} />}
  estimatedItemSize={72}
  keyExtractor={(item) => item.id}
/>
```

**Always provide `estimatedItemSize`.** Without it, FlashList falls back
to FlatList performance.

**Never nest** `ScrollView` inside `ScrollView` or `FlatList` inside
`ScrollView`. This breaks virtualization. If you need a scrollable
section above a list, use the list's `ListHeaderComponent`.

**Pull-to-refresh** via `RefreshControl` on the list. Expected UX on
both platforms.

**Infinite scroll** via `onEndReached` + `onEndReachedThreshold={0.5}`
paired with TanStack Query's `useInfiniteQuery`.

**Separators:** use `ItemSeparatorComponent`, not margin on each row
(margins double-count on re-renders).

**Empty state:** `ListEmptyComponent` with full empty-state design,
not just "No items."

**Keyboard dismiss on scroll:** `keyboardDismissMode="on-drag"` on
forms with scrolling input.

## Part 9 — Forms

Every form uses React Hook Form + Zod, same pattern as web.

```tsx
const schema = z.object({ email: z.string().email() });
const { control, handleSubmit, formState: { errors, isSubmitting } } = useForm({
  resolver: zodResolver(schema),
});

<Controller
  control={control}
  name="email"
  render={({ field: { onChange, onBlur, value } }) => (
    <Input
      label="Email"
      value={value}
      onChangeText={onChange}
      onBlur={onBlur}
      error={errors.email?.message}
      keyboardType="email-address"
      autoCapitalize="none"
      autoComplete="email"
      textContentType="emailAddress"
    />
  )}
/>
```

**Keyboard types matter.** `email-address`, `numeric`, `decimal-pad`,
`phone-pad`, `url`. Never leave a number field defaulting to the text
keyboard.

**Autofill.** `textContentType` (iOS) and `autoComplete` (Android)
enable native autofill for credentials, addresses, OTP. Critical for
conversion on login/signup flows.

**Return key behavior.** Multi-field forms: each input has
`returnKeyType="next"` and focuses the next field on submit, with the
last input using `returnKeyType="done"` to submit the form.

**Validation timing.** Validate on blur for fields user has interacted
with; never validate on keystroke (noisy). Show errors inline beneath
the field with the error color and an icon.

**Submit button placement.** At the bottom of the form, sticky above
the keyboard via `KeyboardAvoidingView`. Disabled during `isSubmitting`;
shows a spinner inside.

**Long forms.** Break into sections with headers. Consider multi-step
(wizard) with progress indicator for forms >10 fields.

## Part 10 — The Four States (Plus Offline)

Every data-driven screen must design all four (plus offline):

1. **Loading** — Skeleton matching layout (never a full-screen spinner
   on navigation). For pull-to-refresh, the spinner is inline in
   `RefreshControl`.
2. **Empty** — Icon/illustration + headline + supporting text + primary
   action ("Create your first order"). Never a blank list.
3. **Error** — Retry-capable error state. Network errors get
   offline-aware messaging ("You're offline. We'll sync when you
   reconnect."). Never expose stack traces.
4. **Success** — Content rendered with polish.
5. **Offline** — Detect with `@react-native-community/netinfo`. Show a
   subtle banner when offline. Queue mutations for replay when online
   (TanStack Query's `onlineManager` + `persistQueryClient`).

## Part 11 — Motion & Haptics

Motion on mobile is louder than on web. Every transition is felt, not
just seen. Rules:

**Reanimated worklets** for anything interactive. Gestures, drags,
bottom sheet physics. Never animate with `setState` on every frame.

**Shared element transitions** for hero images that persist across
screens (use `react-native-reanimated` v3's shared transitions API,
available in React Navigation 7+).

**Layout animations** for list add/remove (use `Layout` + `FadeIn` /
`FadeOut` from Reanimated).

**Spring physics by default** for interactive motion, timing for
deterministic transitions:

```ts
withSpring(1, { damping: 15, stiffness: 120 });
withTiming(1, { duration: tokens.motion.duration.normal });
```

**Haptics via `expo-haptics`:**

- `Haptics.impactAsync(ImpactFeedbackStyle.Light)` — taps on primary buttons
- `Haptics.impactAsync(ImpactFeedbackStyle.Medium)` — toggles, selections
- `Haptics.notificationAsync(NotificationFeedbackType.Success)` — successful mutations
- `Haptics.notificationAsync(NotificationFeedbackType.Error)` — errors, denied actions
- `Haptics.selectionAsync()` — picker scrolls, tab changes

iOS has much richer haptics than Android. Use `Platform.select` where
granularity matters; Android gracefully degrades to simpler vibration.

**Respect Reduce Motion** (iOS) and Remove animations (Android). Check
with `AccessibilityInfo.isReduceMotionEnabled()` and disable
non-essential animation.

## Part 12 — Images & Media

**Never use the built-in `<Image>`.** Use `expo-image`:

- Automatic caching, memory + disk
- `transition` prop for fade-in on load (`transition={200}`)
- `priority` prop (`priority="high"` for above-the-fold, `"low"` for
  off-screen)
- Placeholder support (blurhash, thumbhash, or static placeholder)
- Handles format negotiation

**Always specify dimensions** to prevent layout shift. If dimensions
are dynamic, use `aspectRatio` style.

**Remote images** must have error handling and loading state. Use
placeholder blurhash for smooth UX.

**Icons:** prefer SVG-based icon sets (`lucide-react-native`) over
raster. Size with `size` prop, color with `color` prop. Tappable icons
need a parent `Pressable` with 44×44 minimum hit slop.

## Part 13 — Accessibility

Mobile accessibility is richer than web. Requirements:

- **VoiceOver (iOS) and TalkBack (Android):** every interactive element
  has `accessibilityLabel`, `accessibilityRole`, and `accessibilityHint`
  where purpose isn't obvious.
- Group related content with `accessibilityElementsHidden` on children
  + `importantForAccessibility="yes-exclude-descendants"` on parent, or
  use `accessible={true}` on the group.
- **Dynamic Type / Font Scale support** — test at 130% and 200% scaling.
  Layouts must reflow, not truncate silently.
- **Color contrast:** 4.5:1 for normal text, 3:1 for large text and UI.
- **Touch targets:** 44×44 minimum (iOS HIG), 48×48 preferred (Android
  Material). Use `hitSlop` to extend hit area without visually
  enlarging.
- **Focus management:** after navigation, focus should move to the
  screen's primary heading. Use
  `AccessibilityInfo.setAccessibilityFocus()`.
- **Reduce motion:** see Part 11.
- **Reduce transparency (iOS):** check
  `AccessibilityInfo.isReduceTransparencyEnabled()` and replace blur
  with solid backgrounds.
- **Bold text (iOS):** check `AccessibilityInfo.isBoldTextEnabled()` —
  native fonts handle this automatically if you use system fonts.
- **Screen reader announcements** for dynamic content:
  `AccessibilityInfo.announceForAccessibility('Order saved')`.

Test with VoiceOver (iOS: triple-click home/side button) and TalkBack
(Android: accessibility shortcut) on real devices.

## Part 14 — Platform-Specific Polish

These details separate "RN app" from "app that happens to be built in RN":

**iOS-specific:**

- Large title headers on top-level list screens
  (`headerLargeTitle: true`)
- Swipe-back gesture enabled (`gestureEnabled: true`)
- Haptic feedback on every primary action
- Context menus via `expo-context-menu` or
  `react-native-ios-context-menu` for long-press on list items
- Dynamic Island / Live Activities support for ongoing operations
  (deliveries, timers) via `expo-modules`
- Home Screen widgets via Expo config plugins
- Share sheet via `Share.share()` (native)
- Blur backgrounds via `expo-blur` (`BlurView`)

**Android-specific:**

- Predictive back gesture support (Android 14+): ensure back handling
  works with gesture, not just button
- Edge-to-edge display (`edgeToEdge: true` in Expo config), handle
  system bar insets properly
- Material You dynamic color (optional — most branded apps don't adopt
  this)
- Ripple feedback on all pressable surfaces (`android_ripple` prop on
  `Pressable`)
- Bottom sheet is the default for action sheets and pickers
- Snackbars at the bottom (not top)
- FAB (Floating Action Button) for primary screen action on
  content-heavy screens

**Cross-platform but often missed:**

- Status bar styling per screen: `<StatusBar style="auto" />` from
  `expo-status-bar` per screen, not app-level
- Orientation lock for phone screens, allow landscape on tablets for
  appropriate screens
- Keyboard toolbar with Done button (iOS) via `InputAccessoryView`
- Pasteboard integration for OTP auto-fill (iOS does this with
  `textContentType="oneTimeCode"`)

## Part 15 — Data, Offline & Sync

TanStack Query is the baseline for server state, same as web. Mobile
adds offline considerations:

**Persist the query cache** with
`@tanstack/query-async-storage-persister`:

```ts
persistQueryClient({
  queryClient,
  persister: createAsyncStoragePersister({ storage: AsyncStorage }),
  maxAge: 1000 * 60 * 60 * 24, // 24h
});
```

**Offline detection:** `@react-native-community/netinfo` drives a
`useIsOnline()` hook. Show an offline banner, disable mutations that
require network, queue them for replay.

**Optimistic updates:** especially important on mobile where network
is flaky. Update UI immediately, show a subtle pending indicator, roll
back on error with a toast.

**Background sync:** for apps that must sync when backgrounded, use
`expo-task-manager` + `expo-background-fetch`.

**Secure storage:** `expo-secure-store` for auth tokens (uses iOS
Keychain, Android Keystore). Never `AsyncStorage` for credentials.

## Part 16 — Anti-Patterns (Forbidden)

Never do any of these:

- Use `ScrollView` with `.map()` for dynamic lists — always
  FlashList/FlatList
- Use bare `Image` from `react-native` — always `expo-image`
- Use bare `StatusBar` from `react-native` — always `expo-status-bar`
- Use the deprecated `SafeAreaView` from `react-native` — always from
  `react-native-safe-area-context`
- Use the deprecated `Animated` API for new code — always Reanimated v3
- Use `TouchableOpacity` / `TouchableWithoutFeedback` /
  `TouchableHighlight` — always `Pressable`
- Set status bar color in app-level config — always per-screen
  `<StatusBar />`
- Hardcode colors, spacing, font sizes — always tokens
- Use `Platform.OS === 'ios'` inline everywhere — use `Platform.select`
  or `.ios.tsx` / `.android.tsx` files
- Use web patterns (hover states, right-click menus, keyboard shortcuts
  as primary interaction)
- Assume network is available — every mutation handles offline
- Show full-screen spinners during navigation — always skeleton
- Use a Drawer when Bottom Tabs would work
- Tiny touch targets (<44×44)
- Text without considering Dynamic Type scaling
- Custom pickers when native platform pickers would feel better
- Auto-playing videos with sound
- Modals that can't be dismissed with the native gesture (swipe down on
  iOS, back gesture on Android)
- Web fonts loaded over the network (use `expo-font` to bundle locally)
- `console.log` left in production code
- `any` types
- Business logic in components — always in hooks
- Direct API calls in components — always through generated client +
  TanStack Query hooks

## Part 17 — Project Structure

```text
src/
  api/
    generated/           # Swagger-generated client (shared contract with web)
    client.ts            # Configured client instance with auth
  components/            # Shared UI primitives (Button, Input, Card, etc.)
  features/
    <feature>/
      screens/           # Screen components registered with navigation
      components/        # Feature-specific components
      hooks/             # Feature-specific hooks (useOrders, etc.)
      api/               # TanStack Query wrappers over generated client
      types/             # Feature-specific types
      index.ts
  navigation/
    RootNavigator.tsx    # Top-level navigator
    AuthNavigator.tsx    # Unauthenticated stack
    AppNavigator.tsx     # Authenticated stack (usually tabs)
    linking.ts           # Deep link config
    types.ts             # Route param types
  theme/
    tokens.ts            # Design tokens
    useTheme.ts          # Hook returning scoped tokens
    ThemeProvider.tsx    # Wraps app, provides tokens + color scheme
  utils/
    haptics.ts           # Centralized haptic calls
    format.ts            # Intl number/date formatters
    network.ts           # NetInfo hook, offline queue
  App.tsx
```

Feature folders mirror the web frontend structure — this is intentional
so developers moving between codebases feel at home, and so the
Swagger-backed patterns stay symmetrical.

## Part 18 — Workflow Before Writing Code

For every new screen or feature, **before coding**:

1. Restate the user story and acceptance criteria.
2. List screens and the primary flow, including navigation type (stack
   push / modal / tab).
3. Identify platform divergences — is there a place where iOS and
   Android should differ?
4. Identify components from the core library; note any new ones needed.
5. Identify the four+one states (loading, empty, error, success,
   offline) and how each renders.
6. Identify API endpoints from the generated client and the TanStack
   Query keys + cache strategy.
7. Identify form validation rules and build the Zod schema.
8. Identify haptics moments — which actions deserve feedback?
9. Identify accessibility requirements — labels, roles, focus order.
10. Sketch the layout in prose, including safe area handling and
    keyboard behavior.
11. Only then write code.

**After coding:**

- Test on both iOS simulator and Android emulator minimum (real devices
  preferred for haptics and gestures).
- Test with VoiceOver and TalkBack.
- Test at 130% Dynamic Type scaling.
- Test in offline mode.
- Test in landscape (if supported) and on tablet sizes.
- Test dark mode.
- Run `npm run typecheck` and `npm run lint`.
- Confirm no forbidden patterns from Part 16.

## Part 19 — Definition of Done

A mobile screen is not complete until:

- Works on iOS and Android, real devices, current + one prior OS version
- All five states implemented (loading, empty, error, success, offline)
- Matches design tokens (no raw values)
- Haptic feedback on primary actions
- Keyboard avoidance works
- Safe areas handled correctly (including landscape)
- Pull-to-refresh on list screens
- VoiceOver and TalkBack announce logically
- Dynamic Type up to 130% doesn't break layout
- Dark mode implemented
- No TypeScript errors, no lint warnings
- No forbidden patterns
- Traceable to user story, prototype screen, and API endpoint

When you finish a feature, produce a summary listing: screens built,
components used, platform divergences applied, states handled, haptic
moments, and any deviations from the prototype with justification.

## How This Skill Is Used

- Whenever the user requests mobile work, React Native components,
  screens, navigation, or any mobile frontend implementation, apply
  everything above by default.
- If a request conflicts with these rules, surface the conflict before
  coding — don't silently lower the bar.
- The four highest-leverage sections are **Part 1 (unify vs diverge)**,
  **Part 3 (tokens)**, **Part 8 (lists — this is where perf dies)**,
  and **Part 16 (anti-patterns)**. Keep these intact even if other
  sections get summarized under context pressure.
- **Part 18 (workflow)** is what turns "generates plausible code" into
  "thinks like a mobile engineer first" — follow it on every non-trivial
  screen.

## Related Skills

- `/react-native-design-review` — feedback-sensor counterpart that
  reviews mobile code against this guide
- `/fluent-v9-mastery` — sister skill for web frontend (same Swagger
  contract, symmetrical patterns)
- `/react-ui-design-patterns` — shared async-state and data-fetching
  patterns that apply to both web and mobile
