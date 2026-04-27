---
name: react-native-design-review
description:
  Rigorous React Native + Expo mobile design-and-implementation review for
  iOS and Android. Activates when the user asks to review, audit, or critique
  mobile app code; when a mobile feature is declared done; or automatically
  at the end of mobile feature implementation. Assumes the
  react-native-mastery skill is the source of truth — any code that violates
  it is a finding. Catches every violation before it ships, on both platforms.
metadata:
  companion-skill: react-native-mastery
  slash-command: /mobile-design-review
  severity-levels: [blocker, critical, major, minor, nit]
  version: '1.0.0'
  applies-to: mobile-code-review, pre-merge-gate, ios-android-parity-check
  platforms: [ios, android]
---

# React Native Mobile Design Review

You are performing a rigorous design and implementation review of React
Native mobile code. Your job is to catch every violation before it ships
— the same standard as a senior mobile engineer at a platform-first
company. You review against the **react-native-mastery** guide as the
source of truth.

## How to Run This Review

**Step 1 — Scope.** Determine what to review:

- If the user named a feature, path, or file, review exactly that scope.
- If the user just said "review," review the most recently modified
  mobile files.
- Whole-feature review includes every file under
  `src/features/<feature>/`.

Report the scope back:
> "Reviewing: `src/features/orders/` — 14 files, ~1,120 lines. Target
> platforms: iOS + Android."

**Step 2 — Read everything in scope end to end.**

**Step 3 — Run all 17 review categories below.**

**Step 4 — Produce the Review Report in the specified format.**

**Step 5 — On approval, apply fixes grouped by severity.**

## Severity Levels

- 🔴 **Blocker** — Ships broken, inaccessible, or crashes on one
  platform. Must fix before merge.
- 🟠 **Critical** — Noticeably unprofessional, degrades UX, or fails
  native expectation on one platform. Must fix before merge.
- 🟡 **Major** — Visibly off-brand, wrong pattern, or misses polish.
  Fix this sprint.
- 🔵 **Minor** — Refinement opportunity. Fix when touching the file.
- ⚪ **Nit** — Subjective preference.

## Review Categories

### 1. Platform Handling

**Blockers:**

- Code that only works on one platform without a fallback (iOS-only API
  called unconditionally)
- `Platform.OS === 'web'` checks in a mobile-only app (likely
  copy-pasted from web)
- Assuming APIs exist that don't on one platform (e.g., Haptics called
  without `Platform.select` on older Android)

**Critical:**

- Missing iOS/Android divergence where convention demands it (tab bar
  position, back behavior, system fonts)
- Platform divergence for its own sake where unification would be better
- Not respecting iOS swipe-back gesture
- Not respecting Android predictive back gesture (API 34+)

**Major:**

- Repeated inline `Platform.OS === 'ios'` ternaries that should be a
  single `Platform.select` or `.ios.tsx` / `.android.tsx` file split
- Using a cross-platform icon where a system icon (SF Symbols on iOS,
  Material on Android) would feel more native

Verify: grep for `Platform.OS` — if it appears >5 times in one file,
that's a refactor candidate.

### 2. Stack Compliance

**Blockers:**

- Using deprecated components: `Image` from `react-native` (should be
  `expo-image`), `SafeAreaView` from `react-native` (should be from
  `react-native-safe-area-context`), `StatusBar` from `react-native`
  (should be `expo-status-bar`)
- Using deprecated `Animated` API for new code instead of Reanimated v3
- Using `TouchableOpacity` / `TouchableHighlight` /
  `TouchableWithoutFeedback` instead of `Pressable`

**Critical:**

- Not TypeScript strict, or `any` types present
- Using bare JS Stack navigator instead of Native Stack without
  justification
- Custom storage solution instead of `expo-secure-store` for sensitive
  data

### 3. Design Tokens

**Blockers:**

- Hex colors, `rgb`/`hsl`, or named colors in `StyleSheet.create`
  blocks (only `tokens.ts` may contain these)
- Raw pixel values for spacing (`padding: 16`) that should reference
  `tokens.space.lg`
- Raw font sizes, weights, or line heights outside `tokens.ts`

**Critical:**

- Shadows written inline instead of using `tokens.shadow.*`
- Border radii as raw numbers instead of `tokens.radius.*`
- Motion durations as raw numbers instead of `tokens.motion.duration.*`

**Major:**

- Inconsistent spacing rhythm within a feature (`space.md` in one card,
  arbitrary `14` in another)
- Colors referenced directly instead of through the `useTheme()` hook
  (breaks dark mode)

Show violations with `file:line` and correct replacement.

### 4. Typography

**Blockers:**

- Bare `<Text>` with inline `fontSize` / `fontWeight` styles in screens
  (should use `<Text variant="...">`)
- `allowFontScaling={false}` without a documented reason (breaks
  accessibility)

**Critical:**

- Custom fonts used for body text (should be system fonts on both
  platforms unless brand requires)
- Text hierarchy via color only (no size/weight variation)
- Missing `numberOfLines` on text that could overflow (list items,
  titles)

**Major:**

- Line heights that are too tight (<1.3 for body)
- All-caps text without letter spacing
- Numbers in tables not right-aligned

### 5. Safe Areas & Layout

**Blockers:**

- Screen not wrapped in `SafeAreaView` from
  `react-native-safe-area-context`
- Content overlapping the notch, home indicator, or camera cutout
- Bottom action buttons hidden behind the home indicator on iPhone

**Critical:**

- Missing `KeyboardAvoidingView` on screens with text input
- `KeyboardAvoidingView` using the same `behavior` on both platforms
  (should differ: `padding` iOS, `height` Android)
- Primary actions at the top of long scrolling forms (should be sticky
  at bottom for thumb reach)

**Major:**

- No max-content-width on tablets (content stretches full-width)
- Horizontal padding inconsistent across screens
- Landscape orientation breaks layout (when landscape is supported)

### 6. Navigation

**Blockers:**

- Using `createStackNavigator` instead of `createNativeStackNavigator`
  without justification
- Bottom tabs with >5 tabs
- Modal screens that can't be dismissed by native gesture

**Critical:**

- Drawer used where Bottom Tabs would fit
- iOS missing large title headers on top-level list screens where
  appropriate
- Android using iOS-style centered titles
- Back button showing incorrect label on iOS (previous screen's title)
- Forms with unsaved changes not intercepting `beforeRemove`
- Deep linking not configured

**Major:**

- Screen params typed as `any` instead of via a typed
  `RootStackParamList`
- Nested navigators where a single flat stack would be cleaner
- Header right actions with touch targets <44

### 7. Component Primitive Selection

**Blockers:**

- Hand-rolled button with `<Pressable>` + styling inline, duplicated
  across screens, instead of a shared `<Button>` component
- Native `Picker` component used (known-ugly on both platforms)
- `Alert.alert` used for complex forms or rich content (should be modal
  or bottom sheet)

**Critical:**

Wrong primitive for the job:

- BottomSheet for a simple confirmation (should be Alert)
- Alert for a multi-field form (should be modal)
- Custom modal instead of React Navigation modal presentation
- Toast at top on Android (should be bottom)
- Snackbar at top on Android (should be bottom)
- IconButton without `accessibilityLabel`

**Major:**

- Multiple primary buttons on one screen
- FAB (Floating Action Button) on iOS (Android pattern, not iOS)
- Buttons without haptic feedback on primary actions

### 8. Lists & Performance

**Blockers:**

- `ScrollView` + `.map()` over dynamic data (must be FlashList/FlatList)
- Nested `ScrollView` / `FlatList` / `FlashList`
- List without `keyExtractor`
- `FlashList` without `estimatedItemSize`

**Critical:**

- No pull-to-refresh on primary list screens
- No `ListEmptyComponent` (empty lists show as blank)
- Separator via `marginBottom` on each row instead of
  `ItemSeparatorComponent`
- Infinite scroll not implemented where data is paginated
  (`onEndReached` missing)

**Major:**

- `FlatList` used for lists >50 items or with variable row heights
  (should be `FlashList`)
- `keyboardDismissMode` not set on forms with scrolling input
- Re-rendering list items on every parent re-render (missing
  `React.memo` on row component)

### 9. Forms & Validation

**Blockers:**

- Form built with raw `useState` instead of React Hook Form
- No validation schema (Zod or equivalent)
- Required fields submittable when empty
- Wrong `keyboardType` on number/email/phone fields (defaulting to
  text)

**Critical:**

- `textContentType` (iOS) missing on password, email, OTP, name,
  address fields (breaks autofill)
- `autoComplete` (Android) missing on same (breaks autofill)
- Return key behavior not configured (no focus chain between fields)
- Submit button not disabled during `isSubmitting`
- No loading indicator inside submit button during mutation
- `autoCapitalize="none"` missing on email, username fields

**Major:**

- Validation fires on every keystroke instead of on blur
- Required fields not visually marked
- Error messages generic ("Invalid") instead of actionable ("Enter an
  email like name@example.com")
- Long forms not broken into sections or steps

**Minor:**

- Default values not set in `useForm`
- Missing hint text on non-obvious fields

### 10. The Five States

For every data-driven screen:

**Blockers:**

- No error state (errors swallowed or app crashes)
- No loading state (blank screen during fetch)
- No offline handling (mutations fail silently when offline)

**Critical:**

- No empty state (empty list renders blank)
- Loading state is a full-screen spinner on navigation (should be
  skeleton)
- Error state has no retry action
- Offline state has no indicator (user doesn't know they're offline)
- Success state flashes content before loading resolves

**Major:**

- Empty state is text-only (no illustration, no CTA)
- Error messages expose stack traces or technical details
- Skeleton shape doesn't match final layout
- No differentiation between network error and server error

### 11. Data, Offline & Sync

**Blockers:**

- Direct `fetch` calls bypassing the generated Swagger client
- `useEffect` + `fetch` pattern anywhere (should be TanStack Query)
- Auth tokens in `AsyncStorage` (must be `expo-secure-store`)

**Critical:**

- No query cache persistence (cold start refetches everything)
- No offline detection (NetInfo not used)
- Mutations not queued for offline replay when it matters
- Missing `onSuccess` cache invalidation (stale data after save)

**Major:**

- No optimistic updates for obvious patterns (toggles, favorites)
- Query keys inconsistent across feature
- Background refetch interval too aggressive (battery/data drain)

### 12. Motion & Haptics

**Critical:**

- Haptic feedback missing on primary actions (button presses, toggles,
  successful mutations)
- Haptic feedback on every interaction (overkill, degrades perception)
- Animation built on `Animated` instead of Reanimated for new code
- Spring physics parameters that feel wrong (over-damped, too stiff)

**Major:**

- Reduce Motion not respected (`AccessibilityInfo.isReduceMotionEnabled`)
- Hard-coded durations instead of `tokens.motion.duration.*`
- Using `easing: 'linear'` on entrance animations (should be decelerate)
- Layout animations missing on list add/remove where expected

**Minor:**

- Haptic styles don't match intent (heavy impact for a toggle)

### 13. Accessibility

**Blockers:**

- Icon-only button without `accessibilityLabel`
- Text input without label (placeholder-as-label)
- `accessible={false}` on interactive elements
- Custom `Pressable` without `accessibilityRole="button"`
- Touch target <44×44 without `hitSlop` compensation

**Critical:**

- `allowFontScaling={false}` on body text
- Dynamic Type at 130% breaks layout (overflow, truncation of critical
  info)
- VoiceOver/TalkBack reads screen in wrong order (missing grouping or
  focus management)
- No screen reader announcement after navigation (focus doesn't move
  to heading)
- `accessibilityHint` missing where action is ambiguous
- Color as the only signal (red error text without icon)

**Major:**

- Focus order doesn't match visual order
- Dynamic content changes without
  `AccessibilityInfo.announceForAccessibility`
- Missing `accessibilityState` on toggles, checkboxes, selected tabs
- Images without `alt` / `accessibilityLabel` or
  `accessibilityElementsHidden`

### 14. Images & Media

**Blockers:**

- Bare `Image` component instead of `expo-image`
- No explicit dimensions or `aspectRatio` (causes layout shift)
- Remote images without error handling or placeholder

**Critical:**

- No caching strategy for remote images
- Raster icons where SVG icon set would serve
- Videos auto-playing with sound
- Full-resolution images loaded when thumbnails would work

**Major:**

- No `priority` prop on above-the-fold images
- Blurhash/thumbhash placeholder missing on hero images
- Icons without parent `Pressable` hit slop (<44×44 effective target)

### 15. Code Quality & Architecture

**Critical:**

- Feature not following
  `src/features/<feature>/{screens,components,hooks,api,types}`
  structure
- Screens >400 lines without decomposition
- Business logic in screen components instead of hooks
- Direct API calls from components (bypassing TanStack Query wrappers)
- `any` types or `@ts-ignore` without justification

**Major:**

- Props interface not named `<Component>Props`
- Render blocks >80 lines not extracted
- Magic strings (status values, roles) repeated across files
- Barrel exports leaking feature internals
- Styles defined inline in JSX instead of `StyleSheet.create`

**Minor:**

- Inconsistent naming (`handleClick` vs `onClick`)
- Unused imports
- `console.log` left in code

### 16. Platform-Specific Polish

**Critical:**

- iOS top-level list screen without `headerLargeTitle: true`
- iOS screen without context menu support where long-press would be
  expected (e.g., list items)
- Android without edge-to-edge display configured
- Android `Pressable` without `android_ripple` (no tap feedback)
- No `<StatusBar />` configured per screen (inherits wrong style)

**Major:**

- iOS missing `textContentType="oneTimeCode"` on OTP input (breaks SMS
  autofill)
- Android missing `autoComplete="sms-otp"` on OTP input
- Blur backgrounds (`BlurView`) not respecting Reduce Transparency
- Share functionality using custom modal instead of native
  `Share.share()`

**Minor:**

- No haptic on tab change
- No haptic on pull-to-refresh completion
- Missing swipe actions on list items where platform convention would
  expect them

### 17. Polish & Copy

**Major:**

- Button labels that aren't verbs (`Submit` instead of `Save`, `OK`
  instead of `Create order`)
- Error messages generic (`Invalid input` vs `Enter an email like
  name@example.com`)
- Empty state copy generic (`No items` vs `You haven't created any
  orders yet`)
- Numbers unformatted (`1234567.89` vs `$1,234,567.89` via
  `Intl.NumberFormat`)
- Dates unformatted (`2025-04-23T14:32:00Z` vs `Apr 23` or `2m ago`)
- Offline banner copy unclear (`Error` vs `You're offline. We'll sync
  when you reconnect.`)

**Minor:**

- Inconsistent capitalization (sentence case vs Title Case)
- Mixing `&` and `and`, `OK` and `Okay`
- Missing loading states' messaging differentiation (just "Loading"
  everywhere)

## Review Report Format

Produce the report in exactly this structure:

````markdown
# Mobile Design Review: <scope>

**Reviewed:** <file count> files, <line count> lines
**Platforms:** iOS <version> / Android <version>
**Date:** <date>
**Overall verdict:** ✅ Ship it | ⚠️ Ship after fixes | ❌ Not ready

## Summary

<2–3 sentences. What's strong, what's the headline issue.>

## Findings by Severity

### 🔴 Blockers (<count>)

1. **<Title>** — `src/path/file.tsx:LINE`
   - **Evidence:** <code snippet>
   - **Why it matters:** <1 sentence>
   - **Platform impact:** <iOS / Android / both>
   - **Fix:**

   ```tsx
   // corrected code
   ```

### 🟠 Critical (<count>)
<same format>

### 🟡 Major (<count>)
<same format>

### 🔵 Minor (<count>)
<one line each with file:line>

### ⚪ Nits (<count>)
<one line each>

## Platform Parity Check

| Concern              | iOS         | Android     | Notes |
|----------------------|-------------|-------------|-------|
| Native feel          | ✅ / ⚠️ / ❌ | ✅ / ⚠️ / ❌ |       |
| Navigation patterns  |             |             |       |
| Haptic feedback      |             |             |       |
| Typography           |             |             |       |
| Touch targets        |             |             |       |
| Safe areas           |             |             |       |
| Keyboard handling    |             |             |       |

## Strengths

<3–5 specific bullets on what was done well.>

## Recommended Fix Order

1. <Blockers grouped logically>
2. <Criticals>
3. <Majors as follow-up>

## Metrics

- Platform handling: <X>/10
- Token discipline: <X>/10
- Component primitive fit: <X>/10
- State coverage (5 states): <X>/10
- Lists & performance: <X>/10
- Forms & validation: <X>/10
- Accessibility: <X>/10
- Motion & haptics: <X>/10
- Offline & data: <X>/10
- Polish & copy: <X>/10

**Overall mobile design quality score: <X>/100**

## Next Steps

<Paragraph. Concrete action. Offer to apply Blockers + Criticals automatically.>
````

## Review Principles

- **Be specific.** Every finding cites file and line.
- **Check both platforms.** Every finding notes platform impact — some
  are iOS-only, some Android-only, most are both.
- **Show the fix.** Every Blocker and Critical includes corrected code.
- **Be proportional.** Strong reviews lead with strengths before
  listing flaws.
- **Reference the mastery guide.** "Violates Part 8: FlashList requires
  `estimatedItemSize` for virtualization to work."
- **Don't invent problems.** Defensible patterns not in the guide get
  "⚪ Consideration," not findings.
- **Separate taste from rules.** Token violations are rules. "I'd use a
  sheet instead of a dialog here" is taste.
- **Check offline and low-connectivity paths.** Mobile reviews must
  check offline behavior, not just happy path.
- **Check both orientations and tablet if supported.** A quick
  landscape/tablet check catches layout assumptions.

## After the Review

If user says "apply fixes":

- Apply all Blockers and Criticals automatically
- Re-run typecheck and lint
- Report what changed, what remains
- Recommend re-review if >10 fixes applied
- Offer to also run on the other platform's simulator if
  platform-specific fixes were made

If the user asks about specific findings, explain reasoning and
reference the mastery guide part.

## Integration Notes

- **Pair with the mastery skill.** This review assumes the
  `react-native-mastery` skill exists and references it. They're
  designed as a set.
- **Run three ways:**
  1. As a slash command: `/mobile-design-review src/features/orders`
  2. As an auto-trigger at end of mobile feature implementation
  3. As a pre-merge gate in CI
- **The Platform Parity table is the secret weapon** — it forces
  reviewers (human or Claude) to mentally check both iOS and Android
  for every concern, rather than defaulting to whichever platform they
  tested on.
- **Score over time.** The 10-dimension scorecard (out of 100) lets you
  track where mobile quality is trending across features. Token
  discipline and primitive fit improve fastest; accessibility and
  polish are the long tail.

When asked to review mobile code, run this entire review by default.
Check both platforms. Don't shortcut categories. The mastery guide is
the bar.
