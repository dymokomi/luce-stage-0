# UX_UI_DESIGN.md

## Purpose

This file defines how design and coding agents should design, implement, and review user experiences in this repository and across related products.

The goal is not merely to produce polished screens. The goal is to create software that helps people understand what is possible, accomplish meaningful work, remain in control, recover from mistakes, and trust the system over time.

These rules synthesize Apple’s Human Interface Guidelines across design principles, foundations, patterns, components, inputs, technologies, and platforms. They also translate UX promises into software-design obligations.

Use this as an operational standard, not an encyclopedia. Consult the current platform HIG for version-specific dimensions, components, and technology requirements.

Where principles conflict, prefer **successful human outcomes, preserved agency, consistency, accessibility, and lower cognitive load over visual novelty**.

A beautiful interface is not automatically usable.
A minimal interface is not automatically simple.
A consistent interface is not automatically good.
A custom control is not automatically distinctive.
An animation is not automatically delightful.
An accessible mode is not a substitute for an accessible product.

---

# 1. The Primary Goal: Help People Achieve Meaningful Outcomes

Begin with the value the software creates for people, not with screens, components, backend capabilities, or visual style.

For every feature, state:

```text
For [person in a real context],
this helps them [achieve an outcome],
without requiring them to [unnecessary burden].
```

If the outcome is unclear, the feature is not ready for interface design.

Measure success by whether people can achieve the outcome safely and confidently, not by whether they notice the interface.

---

# 2. Minimize Human Complexity

UX complexity appears as:

1. **Cognitive load** — too many concepts, choices, states, or steps must be held in mind.
2. **Interaction cost** — a simple intention requires excessive navigation, input, waiting, or repetition.
3. **Uncertainty** — people cannot predict what will happen, whether work is safe, or how to recover.
4. **Inconsistency** — knowledge learned in one place fails in another.

Do not optimize for fewest screens, fewest controls, or fewest words. Optimize for the least total effort required to understand and complete the task.

---

# 3. Preserve Agency and Earn Trust

People should feel that they operate the software, not that the software operates them.

Prefer direct access, clear choices, visible exits, reversible actions, controllable automation, and the ability to cancel or retry.

Avoid forced tours, surprise navigation, hidden commitments, destructive automation, dark patterns, manufactured urgency, and opt-outs that are harder than opt-ins.

Be accurate about data use, progress, cost, consequences, uncertainty, and background activity. Reassuring language cannot repair a deceptive design.

---

# 4. Simplicity Is Focus, Not Emptiness

Present what matters now with enough context to act confidently. Reveal secondary complexity when it becomes relevant.

Do not simplify by:

- hiding essential actions;
- removing labels from unfamiliar icons;
- collapsing distinct concepts into an ambiguous control;
- forcing extra navigation;
- replacing clear language with visual mystery;
- removing capability merely to make a screenshot clean.

Hidden is not the same as simple.

---

# 5. Consistency Is a Product Feature

Related products must share a recognizable interaction grammar.

Keep consistent where the meaning is shared:

- domain vocabulary;
- command names and consequences;
- navigation concepts;
- control semantics;
- state language and feedback;
- keyboard shortcuts;
- accessibility behavior;
- writing voice;
- semantic design tokens;
- icon meaning.

People should be able to transfer knowledge from one part of the product family to another.

---

# 6. Prefer Semantic Consistency Over Pixel Sameness

Consistency means that the same concept behaves predictably. It does not require every platform or context to look identical.

Use this precedence:

1. platform and accessibility expectations;
2. shared product mental model and command semantics;
3. shared design-system roles;
4. local visual optimization.

A Mac command may live in a menu and toolbar while its iPhone counterpart lives in a navigation bar. The presentation differs; the name, availability, effect, and undo behavior remain coherent.

Do not make one platform feel foreign merely to match screenshots from another.

---

# 7. Maintain One Shared Design Language

Treat these as product-wide authorities:

- a glossary of domain terms;
- a command catalog;
- semantic color, type, spacing, and motion tokens;
- a component catalog with state and accessibility contracts;
- approved navigation and feedback patterns;
- content and error-message patterns.

Before inventing a term, component, token, or interaction, check whether the concept already exists.

When a shared pattern changes, update its consumers coherently. Do not let each feature fork its own nearly identical version.

---

# 8. Do Not Preserve a Bad Pattern for Consistency

Consistency reduces learning only when the repeated behavior is understandable and appropriate.

When an existing pattern is harmful:

- define the better pattern;
- choose a deliberate migration scope;
- avoid leaving two unexplained conventions for the same concept;
- update documentation, components, tests, and terminology;
- explain the change when it affects learned behavior.

Mechanical uniformity is subordinate to clarity, safety, accessibility, and platform correctness.

---

# 9. Design the Experience Before the Screen

Before laying out a screen, understand:

- the person’s goal and context;
- what they already know;
- current system state;
- required information and actions;
- what can fail or take time;
- what must be reversible;
- what happens if they leave;
- what should be restored when they return.

Design the sequence, state transitions, and recovery paths before refining pixels. A static mockup must not conceal missing behavior.

---

# 10. Model Tasks, Not Pages

Describe workflows as intentions and state transitions.

Prefer:

```text
choose source
review import
resolve conflicts
confirm result
```

over:

```text
screen 1
modal 2
screen 3
```

Pages and components vary across platforms. The task model should remain coherent.

At each step, people should know why they are there, what they can do, what happens next, and whether their work is preserved.

---

# 11. Use the Person’s Vocabulary

Use terms people recognize from the domain. Avoid exposing database entities, transport terminology, internal jobs, vendor concepts, or team abbreviations.

One concept should have one name unless there is a real distinction. If the UI uses `project`, `document`, `file`, and `asset` for the same thing, the model is fragmented.

Align interface names with the design specification, domain model, commands, analytics, and tests where practical.

---

# 12. Organize Around Meaning, Not Implementation

Information architecture should reflect how people seek information and perform tasks, not backend services or team ownership.

Ask:

- What do people expect to find together?
- What do they need most often?
- What must remain visible while they work?
- What is global, contextual, or object-specific?
- Is the relationship hierarchical, sequential, spatial, or associative?

Do not mirror service boundaries in navigation.

---

# 13. Navigation Must Preserve Place and Context

People should understand where they are, how they arrived, what is selected, and how to return.

Preserve reasonable context across navigation:

- selection;
- scroll position;
- filters and sort order;
- expanded sections;
- view mode;
- draft input;
- window and panel arrangement.

Back must mean back in the person’s journey, not “go to a hard-coded parent.”

---

# 14. Use Navigation Components According to Meaning

- Tabs switch among peer areas.
- Sidebars expose major destinations, sources, or hierarchies.
- Split views preserve selection-detail relationships.
- Navigation stacks support drill-down.
- Segmented controls switch closely related modes or subviews.
- Menus reveal commands or compact option sets.

Do not choose a navigation component merely because it fits the geometry. Avoid competing primary navigation systems in one context.

---

# 15. Respect Platform Conventions

Use platform-standard behavior for navigation, menus, shortcuts, windows, selection, focus, text editing, drag and drop, files, authentication, permissions, sharing, undo, and redo.

Customize when the product’s purpose requires it, not to demonstrate originality.

A cross-platform product should share a mental model and identity while behaving naturally on each platform.

---

# 16. Adapt Layouts; Do Not Merely Scale Them

Preserve the conceptual model, vocabulary, selection, and task state while adapting presentation.

Adapt by reflowing rows into stacks, changing column count, moving secondary content into an inspector, changing navigation presentation, replacing hover-only affordances, and adjusting targets for the input method.

Design from available space, content, and input capabilities rather than device-name conditionals.

Do not shrink a desktop layout until it technically fits on a phone or stretch a phone layout across a desktop workspace.

---

# 17. Responsive Layout Is Explicit Behavior

Define:

- supported size ranges;
- safe areas and system obstructions;
- content priorities;
- minimum geometry for each region;
- transition points between compositions;
- behavior at extreme text sizes;
- behavior with software keyboards and resizable windows.

Test the continuous range, not only canonical screenshots.

---

# 18. Establish a Clear Visual Hierarchy

Use layout, spacing, alignment, typography, color, and material to communicate importance.

Place important content early in reading order. Group related items. Give essential information enough space. Separate content from controls. Use one dominant action only when a dominant action truly exists.

Do not make every element prominent. When everything demands attention, nothing has hierarchy.

---

# 19. Progressive Disclosure Must Remain Discoverable

Reveal secondary complexity when it becomes relevant, while keeping important actions reachable and providing a visible cue that more exists.

Avoid ambiguous icon-only controls, essential hover-only actions, gesture-only capability, deeply nested menus, and an “Advanced” dumping ground.

Progressive disclosure should reduce initial cognitive load without creating unknown unknowns.

---

# 20. Content and Controls Are Different Layers

Content is what people came to see or create. Controls help them act on it.

Keep this distinction clear through placement, material, contrast, persistence, and behavior.

On current Apple platforms, use Liquid Glass primarily for the control layer and standard materials for content. System components receive the platform treatment automatically; custom glass effects should be rare.

Visual layers must correspond to interaction layers.

---

# 21. Typography Must Remain Legible and Hierarchical

Prefer platform text styles, system fonts for dense or small content, readable weights, limited typefaces, and layouts that grow with text.

Avoid light weights at small sizes, fixed-height text containers, decorative body fonts, and truncation where full text is necessary to act.

If using a custom font, implement the scaling and accessibility behavior people receive from system fonts.

---

# 22. Design for Text Expansion

Text changes through accessibility sizing, localization, bolding, live data, pluralization, and user content.

At large sizes, stack inline elements, reduce columns, allow wrapping, preserve primary content, and keep actions reachable.

On Apple platforms, support Dynamic Type or an equivalent robust sizing system. Test the largest accessibility sizes, not just standard sizes.

Do not treat a default-size English screenshot as proof of correctness.

---

# 23. Use Color Semantically

Define colors by meaning, such as `textPrimary`, `surfaceRaised`, `selection`, `warning`, and `destructive`.

Use semantic system colors where practical. Custom colors need light, dark, and increased-contrast variants.

Use the same color consistently and never rely on color alone for selection, validation, status, focus, or chart meaning.

Do not hard-code platform system color values; their appearance can change with context and OS releases.

---

# 24. Materials and Depth Must Convey Structure

Use blur, glass, translucency, vibrancy, shadow, and elevation to communicate separation, hierarchy, interactivity, or temporary presentation.

Choose materials by semantic role, not their current apparent color.

Test with light and dark appearances, Increase Contrast, Reduce Transparency, and visually complex content.

Do not use depth effects as decoration without structural meaning.

---

# 25. Icons Must Express One Recognizable Concept

Prefer familiar system symbols for common actions. Custom icons must be simple, recognizable at small sizes, visually consistent, culturally appropriate, and supplied with accessible labels.

Use text when an icon cannot communicate clearly. Do not mix unrelated icon styles or place unlocalized text inside icons.

Match icon weight to adjacent text and use optical, not merely geometric, alignment.

---

# 26. Motion Must Communicate

Use motion to connect cause and effect, preserve spatial context, show state change, confirm manipulation, or guide attention briefly.

Motion should be purposeful, brief, precise, interruptible, and consistent with platform expectations.

Avoid repeated animation on frequent actions, blocking interaction until motion completes, and motion as the only signal. Always provide an appropriate reduced-motion behavior.

---

# 27. Writing Is Part of the Interface

Use plain language, active voice, familiar terms, concise sentences, actionable labels, and respectful inclusive wording.

Use verbs for actions and nouns for objects, destinations, categories, or view modes. Prefer `Send`, `Save Copy`, or `Review Changes` over clever but ambiguous labels.

Maintain a shared glossary, voice, and message patterns across products. Do not let each feature invent its own terminology or tone.

---

# 28. Feedback Must Be Immediate and Proportional

Every interaction needs a perceptible response showing that input was received and what changed.

Match interruption to importance:

- inline status for local information;
- transient confirmation for a meaningful completed action;
- alerts for critical actionable information;
- notifications for important information outside the current context.

Use multiple sensory channels when helpful, but do not announce routine success so loudly that the product becomes noisy.

---

# 29. Loading Must Be Fast, Honest, and Nonblocking

Show useful structure or available content as soon as possible. Prefer cached content with freshness status, layout-preserving placeholders, background loading, partial results, real determinate progress, and cancellation.

Do not show a blank screen while work occurs. Do not simulate determinate progress with timers or let completion appear before work is committed.

If a task changes phases, label the real phase rather than making the last 10 percent appear stalled.

---

# 30. Empty States Must Explain the Actual Condition

Distinguish first use, intentionally empty content, no search results, filtered-out content, permission restriction, offline data, and load failure.

Explain the condition and offer the next useful action when appropriate.

Do not use the same generic illustration and message for semantically different states. Do not place essential information only in a temporary empty state.

---

# 31. Errors Must Enable Recovery

Prevent errors through constraints, defaults, previews, and timely validation.

When an error occurs, say:

1. what happened;
2. what remains safe;
3. what the person can do next;
4. where to act.

Place guidance near the problem. Avoid blame, raw codes, vague apologies, and messages like `Invalid input` or `Oops`.

If an error affects many people, improve the interaction rather than polishing the message.

---

# 32. Prefer Reversible Actions

Use undo, trash, archive, drafts, version history, reversible transformations, and previews where practical.

Confirmation dialogs are weaker than reversibility because people habituate to warnings. Confirm only when an action is consequential, surprising, difficult to reverse, or affects other people.

Undo should operate on meaningful user actions, support appropriate grouping, describe its result, and reveal the changed content.

The domain model must retain enough information to restore a valid prior state.

---

# 33. Modality Is a Scarce Resource

Use a modal presentation only when separation helps people focus or protects an important decision.

Keep modal tasks short, self-contained, titled, and easy to dismiss. Preserve drafts or explain data loss.

Avoid deep navigation inside modals, stacked modals, multiple alerts, and using modality as a substitute for information architecture.

---

# 34. Onboarding Must Accelerate Real Use

Teach through safe interaction with the real product. Prefer good defaults, sample content, contextual tips, and optional tutorials.

Do not front-load information people cannot contextualize, teach standard system behavior, repeat skipped tours, or delay use for nonessential setup.

Let people experience the product before asking for ratings, purchases, extensive personalization, or unrelated permissions.

---

# 35. Help Must Be Contextual and Task-Oriented

Use inline guidance for simple tasks, tips for short features, tooltips for specific controls, tutorials for complex workflows, and searchable documentation for depth.

Describe what a standard element does in this product, not how buttons work in general.

If a control needs a paragraph of help, simplify the control or task. Do not show guidance to people who have already demonstrated the behavior.

---

# 36. Minimize Data Entry

Do not ask people to type information the system already knows or can obtain with appropriate permission.

Prefer autofill, passkeys, defaults, selection, paste, drag and drop, scanning, and import where appropriate.

When entry is necessary, use persistent labels, the correct keyboard, expected format, autofill semantics, timely validation, and preserved input after failure. Placeholder text may be a hint, never the only label.

---

# 37. Forms Must Express Structure and Progress

Group related fields and order them by the person’s task. Distinguish required and optional input. Preserve data when moving back or recovering from failure.

For multistep forms, keep action labels consistent, show progress when helpful, save drafts when interruption is plausible, and summarize consequential submissions.

Do not disable submission without revealing what remains incomplete.

---

# 38. Defaults and Settings Require Restraint

Choose safe, reversible defaults that let most people begin immediately and respect system preferences.

Use settings for general choices people change infrequently. Keep task-specific options near the task. Avoid redundant app-level versions of appearance, accessibility, authentication, and other system settings.

Every setting creates implementation, testing, migration, and support cost. Add one reluctantly.

---

# 39. Search Must Have a Clear Scope

If search is important, give it a primary, predictable location. Show what is being searched, which filters are active, how to clear the query, and why no results appeared.

Help people type less with suggestions, recent searches, or completion when appropriate.

Treat search history as potentially private and let people clear it.

---

# 40. Choose Data Views by Information Shape

Use lists for scannable rows, tables for aligned columns, grids for visual collections, trees for hierarchy, and split views when selection and detail benefit from simultaneous visibility.

Support sorting, resizing, selection, copy, keyboard traversal, and contextual commands where the platform and data call for them.

Preserve stable item identity and clear selection feedback. Do not force hierarchy into indentation without disclosure semantics.

---

# 41. Commands Need One Semantic Source

The same command may appear in a button, menu, context menu, toolbar, shortcut, voice action, or automation surface.

Define it once with:

- identity and label;
- icon and role;
- availability;
- shortcut;
- execution behavior;
- undo description;
- accessibility description.

Do not let presentations drift into different labels, enabled states, or consequences.

---

# 42. Buttons and Menus Must Communicate Role

Use clear verb labels and familiar symbols. Give custom buttons a visible press state. Keep prominent actions to one or two in a typical view and never make a destructive action the default.

Menus should prioritize frequent or important commands, preserve stable grouping, show unavailable commands when discovery matters, and use an ellipsis when more input is required.

Do not hide a primary action only in a context menu or fill a toolbar with every capability.

---

# 43. Selection, Focus, Hover, and Press Are Distinct

- Selection identifies chosen content or a persistent mode.
- Focus identifies the element receiving keyboard, remote, switch, or gaze input.
- Hover indicates interest before activation.
- Press indicates active input.
- Disabled indicates known but unavailable behavior.

Each applicable state needs a perceptible, accessible treatment. Do not use hover as the only way to reveal required behavior or let focus disappear against selection.

---

# 44. Support Multiple Inputs Intentionally

People may use touch, pointer, trackpad, keyboard, remote, controller, stylus, voice, switches, or eye and hand input.

Support platform gestures and focus behavior. Provide visible alternatives to gestures for core actions. Ensure logical keyboard order, visible focus, activation, dismissal, and standard shortcuts.

The input used during development is not the only input that matters.

---

# 45. Direct Manipulation Must Remain Predictable

Dragging, resizing, rearranging, drawing, and scrubbing should track input continuously and provide immediate feedback.

Show the affected object, valid destinations, constraints, snapping, prospective result, and invalid drop state. Allow cancellation without committing a partial result.

Do not wait until release to reveal that an operation was impossible.

---

# 46. Accessibility Is a Foundation, Not a Mode

Accessibility must influence information architecture, components, content order, target size, typography, color, motion, sound, focus, testing, and release criteria from the beginning.

An accessible interface is understandable, perceivable through more than one channel, operable through multiple inputs, and adaptable to system settings and assistive technologies.

Do not postpone accessibility until the visual design is complete.

---

# 47. The Accessibility Tree Is an Interface Contract

For each meaningful element, define:

- role;
- accessible name;
- value and state;
- actions;
- grouping and reading order;
- focus behavior;
- updates that require announcement.

Prefer native semantic components. Custom-drawn UI must recreate semantics and behavior explicitly.

Do not mirror decorative view nesting in the accessibility tree.

---

# 48. Do Not Communicate Through One Sense Alone

Essential information must not depend solely on color, sound, haptics, motion, position, or an undescribed image.

Pair color with text, shape, or icon; audio with visual guidance; gestures with controls; video with captions; meaningful images with descriptions; and charts with accessible structure or summaries.

This redundancy increases clarity; it is not waste.

---

# 49. Respect Accessibility Preferences

Support text enlargement, Bold Text, increased contrast, Reduce Motion, Reduce Transparency, captions, and other relevant platform settings.

Test combinations such as largest text at narrow width, Dark Mode with increased contrast, localization with large text, and screen readers with dynamic updates.

On Apple touch platforms, ordinary controls should generally provide at least a 44x44-point hit region; visionOS commonly needs 60x60 points. Treat current HIG values as baselines and verify them for the target platform.

---

# 50. Localization Changes Layout and Meaning

Externalize user-facing text and format dates, numbers, currency, units, and addresses using locale-aware systems.

Account for expansion, plural rules, scripts, fonts, line breaking, input methods, and cultural meaning. Do not concatenate translated fragments or embed live text in images.

Give translators context for short strings and test at least one expanded localization.

---

# 51. Right-to-Left Support Is Semantic

Use leading and trailing relationships rather than hard-coded left and right.

Mirror reading-order navigation, progress, and ordered groups. Do not mirror logos, universal marks, digits inside a number, many real-world objects, or controls representing absolute physical direction.

Complex icons may require a designed localized variant rather than mechanical flipping.

---

# 52. Privacy Must Shape Architecture and Interface

Collect only what the feature needs. Prefer on-device processing, narrow scope, short retention, secure storage, explicit deletion, and clear provenance.

The interface must accurately describe what the architecture does. Do not claim data stays private if it leaves the device, enters logs, trains a model, or reaches another processor.

Privacy is not a policy-page concern added after implementation.

---

# 53. Ask for Permission in Context

Request access when the person invokes the feature that needs it. Make the benefit and use clear without imitating or pressuring the system prompt.

Model permission as a state machine:

```text
notDetermined
granted
limited
denied
restricted
unavailable
```

Design useful behavior for every state. Accept denial and provide a direct path to settings when changing the choice is necessary.

---

# 54. Accounts Must Not Be an Unnecessary Gate

Delay sign-in until it is required for meaningful value. Explain the benefit and prefer secure platform authentication such as passkeys or Sign in with Apple where applicable.

Preserve local work through session expiration. Provide recovery, clear sign-in state, and discoverable export and account deletion where appropriate.

Do not make deletion or cancellation harder than creation.

---

# 55. Notifications Spend a Person’s Attention

Notify only when information is timely, important, and useful outside the app. Assign interruption levels honestly; marketing is never time-sensitive.

Let people control categories and respect Focus and system settings. Deep-link to relevant current context and handle stale content gracefully.

Routine background completion often needs only inline status when the person returns.

---

# 56. Preserve Work and Context Automatically

People should trust that work remains safe unless they explicitly discard or delete it.

Use autosave, durable drafts, atomic writes, crash recovery, version history, conflict detection, and clear sync status where appropriate.

Restore open content, navigation, selection, scroll, filters, drafts, and window arrangement after routine interruption. Do not make people reconstruct their workspace.

---

# 57. Offline and Degraded States Need Design

Define behavior for offline launch, connection loss, stale data, partial sync, expired authentication, server failure, queued local edits, conflicts, retry, and cancellation.

Communicate what is available, stale, queued, or safe. Preserve useful local capability.

Do not block the whole product because one feature needs the network.

---

# 58. Performance Is Part of UX Correctness

Set budgets for launch, input feedback, scrolling, navigation, search, save acknowledgement, large datasets, memory, and energy where relevant.

Responsiveness establishes causality and trust. Never hide synchronous work behind a button with no immediate state change.

Use optimistic UI only when success is likely, failure is recoverable, requests are safe to retry, and reconciliation is explicit.

---

# 59. Long-Running Work Must Be Observable and Controllable

A long task needs stable identity, phase, real progress when measurable, cancellation, retry, background continuation, failure reason, completion outcome, and restoration after restart.

The UI should subscribe to this model, not simulate progress. If cancellation is delayed, show that it is pending.

Do not optimistically report financial, destructive, legal, or externally visible work as complete before commitment.

---

# 60. Every Surface Needs an Explicit State Model

Consider relevant states such as:

```text
initial
loading
empty
content
partial
refreshing
stale
offline
permissionDenied
recoverableError
terminalError
conflict
```

Not every surface needs every state, but every reachable state needs deliberate behavior. Prefer state representations that make contradictory Boolean combinations difficult to express.

---

# 61. UI State Must Have Clear Ownership

Distinguish domain state, navigation state, temporary view state, durable drafts, and derived presentation.

Do not duplicate the same truth across layers. Do not store derived visual state when it can be computed reliably. Do not let a view own durable work merely because it displays it.

Command availability must derive from the same domain rules that govern execution, while still being validated at the execution boundary.

---

# 62. UX Promises Create Software Obligations

| UX promise | Required capability |
| --- | --- |
| Undo | Commands, inverse operations or snapshots, grouping, and history boundaries |
| Autosave | Durable atomic writes, recovery, versioning, and conflict policy |
| Restore my place | Serializable navigation and workspace state with migration |
| Honest progress | Observable task phases and real work units |
| Cancel | Cooperative cancellation and partial-result cleanup |
| Work offline | Cache, local mutations, synchronization, and conflict handling |
| Adaptive layout | Semantic content separated from geometry |
| Accessibility | Semantic components, focus, labels, values, and actions |
| Localization | Externalized messages, locale formatting, and flexible layout |
| Contextual permission | Capability states and denied/restricted fallbacks |
| Safe automation | Preview, confirmation policy, auditability, and rollback |

If the architecture cannot support the promise, change the architecture or the promise before shipping.

---

# 63. Separate Domain Semantics from Presentation

The domain describes what exists and what actions mean. The presentation decides how those concepts appear in the current platform and context.

```text
command: archive selected messages
iPhone: toolbar button
Mac: menu item + shortcut + toolbar item
automation: app intent
```

Do not embed domain meaning separately in each button handler or make the domain depend on a screen, modal, or widget.

---

# 64. Design Systems Must Encode Meaning

A design system is not a gallery of colors and components. It should encode semantic tokens, typography roles, surfaces, command roles, behavior, accessibility, state transitions, content guidance, and platform variation.

Prefer semantic names such as `textSecondary`, `surfaceControl`, and `spaceSection` over raw screenshot constants at the point of use.

Build one shared semantic core with deliberate platform adapters.

---

# 65. Components Must Be Behaviorally Deep

A reusable component should hide meaningful complexity: layout, input, focus, accessibility, appearance, localization, states, and platform adaptation.

For each component, define applicable default, hover, focus, press, selection, disabled, loading, invalid, expanded, and drag states, plus its accessible role and actions.

Prefer native components until a real product need requires more. Avoid wrappers that merely rename native controls or freeze one screenshot.

---

# 66. Prototype the Riskiest Assumption First

Use the lowest-fidelity prototype that can answer the current question: task flows for information architecture, interactive prototypes for navigation, production code for performance or accessibility, and data prototypes for extreme content.

Do not polish pixels while the task model remains uncertain. Prototypes exist to produce learning and may be discarded.

---

# 67. Test Real Tasks With Representative People

Observe whether people know where to begin, understand terms, notice important actions, predict results, and recover without coaching.

Use realistic long, missing, duplicate, extreme, localized, right-to-left, slow, stale, and conflicting content.

Do not ask only whether people like the design. Preference does not replace evidence of comprehension and task success.

---

# 68. Experience Acceptance Criteria Must Be Behavioral

Specify task success, state and recovery behavior, accessibility, inputs, adaptive ranges, localization, loading, performance, privacy, interruption, and offline behavior.

Use unit tests for state and formatting, component tests for semantics, visual tests for stable appearance, end-to-end tests for critical journeys, performance tests for responsiveness, and usability tests for human outcomes.

`Matches Figma` is not sufficient acceptance criteria.

---

# 69. Test the Context Matrix

Test combinations of:

- no, little, typical, and extreme data;
- short and long localized text;
- smallest and largest layouts and text sizes;
- light, dark, and increased contrast;
- reduced motion and transparency;
- relevant input and assistive technologies;
- online, slow, intermittent, and offline states;
- loading, permission, error, conflict, restoration, and migration.

Automate the matrix where practical. Do not depend on memory.

---

# 70. Measure Outcomes Without Surveillance

Prefer task completion, time to meaningful result, error and recovery rate, abandonment, latency, cancellation, and save/sync reliability over raw clicks or time spent.

Collect the minimum telemetry needed. Do not record sensitive content or behavior without necessity, consent, and protection.

Interpret behavior carefully: frequent use can indicate value or friction; rare use can indicate irrelevance or poor discovery. Analytics must not silently redefine the goal as engagement.

---

# 71. Design AI Features Only for Clear Value

Use generative or predictive systems for specific benefits such as time savings, expression, transformation, or assistance with complex information.

Clearly identify AI’s role and limitations. Keep people in control with review, edit, compare, retry, accept, reject, undo, and restore-original actions as appropriate.

Provide a strong non-AI path when AI is complementary, not essential. Do not add AI merely because a model can produce output.

---

# 72. Represent AI Uncertainty and Risk Honestly

Do not present fluent output as certain or human-authored. Use verified current sources when factual errors could matter.

When uncertainty matters, ask for clarification, withhold low-quality proactive results, offer meaningfully different alternatives, or explain attribution. Raw confidence percentages are rarely useful.

Require preview or confirmation for consequential, destructive, financial, externally visible, or difficult-to-reverse actions.

---

# 73. AI Privacy, Latency, and Change Need Explicit Design

Prefer on-device processing when it meets the need. For server processing, minimize context, disclose what is shared and retained, obtain permission for sensitive or training use, and support opt-out and deletion.

Design queued, streaming, cancel, retry, unavailable, offline, and restart states. Use specific status such as `Summarizing selected notes`, not vague simulated activity.

Version evaluations and test ambiguous, biased, harmful, copyrighted, and out-of-scope inputs whenever models, prompts, datasets, or providers change.

---

# 74. Red Flags

Stop and reconsider when you see:

- screenshot-only happy-path design;
- hidden essential actions;
- custom controls without complete semantics;
- gesture-only core behavior;
- stacked modals or routine alerts;
- settings used to avoid design decisions;
- repeated permission pressure;
- simulated progress;
- contradictory Boolean UI state;
- placeholder-only labels;
- color-only meaning;
- decorative motion;
- branding that dominates content;
- desktop shrunk to mobile or mobile stretched to desktop;
- accessibility added as an overlay;
- engagement optimized over human outcome.

These are design failures, not polish tasks.

---

# 75. Agent-Specific Rule: Read Before Designing

Before a significant change:

1. operate or trace the current journey;
2. inspect every affected state and platform;
3. inspect domain, command, navigation, and persistence models;
4. inspect shared terminology, components, and tokens;
5. inspect accessibility and input behavior;
6. inspect relevant tests and prior decisions;
7. identify the human promise being changed.

Do not infer experience from filenames or components alone.

---

# 76. Agent-Specific Rule: Preserve Product Consistency

Before introducing or changing a pattern, search all related products and surfaces for the same concept.

Reuse the shared term, command, component, token, and behavior where semantics match. If the shared pattern is wrong, propose a coherent migration instead of creating a local exception.

When changing navigation, command meaning, accessibility, or visual language, state how consistency is preserved across the product family.

---

# 77. Agent-Specific Rule: Trace Design Into Architecture

For each requirement, identify authoritative state, owner, command, persistence, failure, cancellation, synchronization, accessibility semantics, and test boundary.

If a mockup implies undo, autosave, progress, restoration, offline work, or safe AI automation, implement the system capability or narrow the design explicitly.

Do not fake a durable behavior in the view layer.

---

# 78. Agent-Specific Rule: Verify the Implemented Experience

After changing the interface:

1. complete the primary task on the target platform;
2. test loading, empty, error, permission, cancellation, and restoration;
3. test relevant input methods;
4. test layout extremes, text scaling, appearances, contrast, and reduced motion;
5. test localization and right-to-left behavior where supported;
6. inspect and operate the accessibility tree;
7. profile relevant performance;
8. review the diff for inconsistent terms, components, tokens, and behavior.

Do not claim completion from compilation or snapshots alone.

---

# 79. Decision Framework

Before adding a new screen, component, modal, setting, permission, notification, motion, or AI automation, ask:

- What human problem does it solve?
- Does a shared or native pattern already solve it?
- What new concept or learning cost does it introduce?
- Is it consistent with related products and platform expectations?
- What states, inputs, accessibility, localization, and recovery must it support?
- What architecture makes the behavior true?
- Is the variation real today?
- Can the result be explained and tested simply?

If it adds more total complexity than value, do not add it.

---

# 80. Priority Order

When principles conflict, use this order:

1. **Human safety, dignity, and legal or ethical obligations**
2. **Data preservation, agency, privacy, and informed choice**
3. **Successful completion of the meaningful task**
4. **Accessibility and inclusive operation**
5. **Clear semantics, feedback, and recovery**
6. **Cross-product consistency and low cognitive load**
7. **Platform conventions and predictable behavior**
8. **Reliability, responsiveness, and continuity**
9. **Visual hierarchy and legibility**
10. **Reuse, brand expression, and delight**
11. **Visual novelty and brevity**

Never sacrifice safety or agency for engagement, accessibility for visual purity, or clear behavior for implementation convenience.

---

# 81. The Core Standard

A person should be able to answer quickly:

- What is this for?
- Where am I?
- What matters here?
- What can I do and what will happen?
- Is the system working and is my work safe?
- Can I cancel, undo, or recover?
- What information is being used or shared?
- Can I use my preferred text size, appearance, and input method?
- Does this behave like the rest of the product and the platform?

The team should be able to identify the owner of every visible state, the command behind every action, the architecture behind every UX promise, and the evidence that people can succeed.

If these answers are difficult to discover, the design is not finished.

---

# 82. Final Instruction to Design and Coding Agents

Do not optimize interfaces for demonstrating taste, novelty, or output volume.

Prefer:

- meaningful outcomes over feature count;
- agency over coercion;
- consistent semantics over pixel sameness;
- clear models over clever surfaces;
- native behavior over gratuitous invention;
- reversible actions over repeated warnings;
- honest state over reassuring fiction;
- adaptive layouts over fixed screenshots;
- accessibility by construction over remediation;
- deep shared components over local variants;
- architecture that fulfills the experience over UI that merely promises it;
- verified human success over confidence.

When uncertain, choose the design that helps people understand more, remember less, remain in control, and transfer what they learned to the rest of the product.

---

## Source Basis

This is an original operational synthesis based on the [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines), including its internally linked guidance for [design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles), [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [layout](https://developer.apple.com/design/human-interface-guidelines/layout), [typography](https://developer.apple.com/design/human-interface-guidelines/typography), [color](https://developer.apple.com/design/human-interface-guidelines/color), [motion](https://developer.apple.com/design/human-interface-guidelines/motion), [writing](https://developer.apple.com/design/human-interface-guidelines/writing), [privacy](https://developer.apple.com/design/human-interface-guidelines/privacy), patterns, components, inputs, platform guidance, and [generative AI](https://developer.apple.com/design/human-interface-guidelines/generative-ai), reviewed August 13, 2026.

For implementation, use the current [Apple Design Resources](https://developer.apple.com/design/resources/), platform documentation, accessibility evaluation criteria, and technology-specific HIG rather than copying version-sensitive values into this file.
