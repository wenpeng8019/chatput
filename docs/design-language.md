# ChatPUT Design Language

## Design Direction

ChatPUT is an input bridge, not a content destination. The interface should feel quiet, precise, and dependable: it stays close to the user's hand, avoids decorative noise, and makes connection state, current target, and input controls obvious without shouting.

The long-term visual target is: premium, restrained, spacious, and durable. Prefer small refinements that age well over high-contrast decoration.

## Principles

1. **Quiet confidence**
   - Use neutral surfaces, restrained blue accents, and low elevation.
   - Let hierarchy come from spacing, weight, and state, not heavy shadows or saturated blocks.

2. **Input first**
   - The primary action is always the input affordance: scan on the home screen, voice/text composer in the session screen.
   - Supporting UI should clarify state and target, then get out of the way.

3. **One geometry system**
   - Header cards, session items, and menus share the same panel language.
   - The voice composer keeps its larger 34dp radius because it is a thumb-controlled tool surface; its grab decoration must share the same radius.

4. **State is readable, not loud**
   - Connected/idle/error states should use chips, concise text, and color only as reinforcement.
   - Technical terms should be hidden from user-facing copy unless they are genuinely actionable.

5. **Motion explains structure**
   - Transitions should show where surfaces move and what state changed.
   - Use short, composed motion; avoid bounce or novelty effects.

## Tokens

Android tokens live in:
测试下空调。
- `mobile-android/app/src/main/res/values/colors.xml`
- `mobile-android/app/src/main/res/values-night/colors.xml`
- `mobile-android/app/src/main/res/values/dimens.xml`

### Color

- `chatput_bg`: app background, slightly off-white / dark neutral.
- `chatput_surface`: cards, sheets, popups.
- `chatput_surface_alt`: quiet control background.
- `chatput_surface_active`: pressed or selected control background.
- `chatput_line`: 1dp separators and card strokes.
- `chatput_accent`: primary action and active focus.
- `chatput_accent_strong`: pressed primary action.
- `chatput_accent_soft`: badge, ripple, and subtle selected fills.
- `chatput_text_primary`: primary content.
- `chatput_text_secondary`: subtitles and secondary labels.
- `chatput_text_tertiary`: hints and section labels.
- `chatput_danger`: destructive actions only.

### Radius

- `radius_panel = 22dp`: top panels and session cards.
- `radius_popup = 20dp`: floating menus.
- `radius_list_item = 18dp`: recent device rows and compact repeated rows.
- `radius_input = 14dp`: input fields and popup rows.
- `composer_corner_radius = 34dp`: voice composer and matching corner grab decoration.

### Spacing And Controls

- Use `space_1` through `space_6` for repeated spacing.
- Use `screen_margin = 18dp` for primary screen-side panels.
- Use `control_small = 40dp`, `control_medium = 56dp`, `control_primary = 78dp` for touch controls.

## Component Rules

### Home Header

Before connection, the header can be descriptive. After connection, it should compact into a one-line status bar: product name plus connection status. The session list may push this compact header away when content grows.

### Session Cards

Session cards use `radius_panel`, white surface, 1dp line, and no elevation. The active session is indicated with the left accent bar and badge, not by changing the whole card into a loud color block.

### Voice Composer

The composer is a thumb tool, so it may be larger and rounder than other panels. The side actions are secondary circular controls; the center voice button is the only dominant action.

The drag affordance is decorative and follows the composer corner radius exactly. The center voice button area should not trigger the text-input pull gesture.

### Text Input Sheet

The text input sheet is a rectangular extension of the keyboard edge. It should feel attached to the system keyboard, not like a floating modal. The send button stays 40dp and aligned to the input field height.

### Menus

Use custom PopupWindow menus, not platform default PopupMenu styling. Menu surfaces use `radius_popup`, 1dp stroke, compact row height, and icon + label rows. Destructive rows use `chatput_danger`.

### Copy

Use user language instead of implementation language:

- Prefer `桌面断开` over `信令断开`.
- Prefer device names over window titles when identifying the connected desktop.
- Keep tips short and close to the control they describe.

## Motion

- Header compact transition: 260ms, ChangeBounds + Fade, decelerate.
- Voice-to-text transition: composer lifts and fades while the text sheet fades in.
- Closing system input should restore the voice composer with the inverse transition.

Motion should be functional: it explains continuity between two states.

## Future UI Checklist

Before adding a new UI element:

1. Can it reuse an existing token for radius, spacing, and color?
2. Is it primary, secondary, state, or destructive?
3. Does it need text, or can the icon plus accessibility label carry it?
4. Does it compete with the input control?
5. Will it still look calm after seeing it every day for a month?
