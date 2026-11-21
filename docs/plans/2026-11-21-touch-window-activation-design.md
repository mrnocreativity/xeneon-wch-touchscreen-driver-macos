# Activate touched windows before input

## Approved behavior

When another application is active, one touch on a browser control should activate
the exact visible window beneath that touch, deliver one normal interaction, and
restore the previously focused application and window and the cursor position.
Activation uses documented Accessibility and AppKit APIs, never an extra click.
Only verified target focus permits synthetic input. A failure cancels the gesture.
Restoration must respect a switch to a different window during the interaction.

## Integration

Extend the focus abstraction with asynchronous target preparation and a focus
ownership check. Resolve the window under the mapped desktop point through AX
hit testing, activate its application and exact window on the main queue, and
poll focus with a short deadline without blocking HID routing. The gesture queue
retains incoming movement and release while activation is pending, then resumes
normal classification in order. Cancellation invalidates pending preparation.
Recheck routing authority and target ownership before starting input. Keep an
already-started mouse gesture balanced on cancellation.

Capture the original focus once per gesture sequence. Preserve the existing
double-click interval and prompt cursor return. Scroll and hold-drag use the same
preparation. If the target is already focused, preparation completes immediately.
If the user changes focus away from the target, skip input and skip restoration.
All target identity and geometry are discovered dynamically.

## Implementation steps

1. Add a testable focus-activation transaction with bounded asynchronous polling,
   cancellation, and conditional restoration.
2. Implement AX point-to-window resolution and exact-window activation.
3. Gate gesture input on preparation, safely handle release/move/cancellation while
   waiting, and preserve existing double-click and storm authority checks.
4. Test event ordering, failed/late activation, cancellation, focus ownership,
   dragging, scrolling and double-clicking; run the full suite and release build.
5. Update through the canonical signed installer and read back service status.
   Have the user physically test an inactive browser with another app active.

## Acceptance

With Mail active and a browser on a paired touchscreen, one physical tap triggers
exactly one page action and returns focus to the original Mail window. Repeat
with two browser windows, both touchscreens, a double-click, scroll, hold-drag,
and a deliberate focus change during the restoration interval. Observe real DOM
pointer events without browser focus emulation. Automated tests alone cannot
prove native inactive-window delivery or physical display behavior.

## Local verification

On November 21, 2026, all 185 Swift tests passed with warnings treated as errors,
and the release build passed with the same compiler setting. Whitespace checks
passed. Tests include focus activation deadlines, exact-window identity, missing
targets, cancellation and late callbacks, user focus changes, restoration failure,
focus handoff between controllers, buffered taps and scrolling, and existing
gesture and pairing regressions.

The connected-hardware check found no supported USB touch controller, setup
reported `waitingForHardware`, and display enumeration found only the built-in
display. The installed driver was therefore left unchanged. Signed installation,
real browser pointer-event observation, and physical touch acceptance remain
pending connection of the external display and its USB touch interface.
