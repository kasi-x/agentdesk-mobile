# Extractable components

All components are vanilla-JS render functions + CSS (no framework). Petite-Vue conversion is possible but this is a single page — inline HTML in drafts is more faithful. Listed for completeness:

## TopBar
- Source: `web/index.html` + `web/style.css` (#topbar)
- Category: layout
- Description: sticky bar — brand name + connection dot + pending-count pill + ⚙設定 button
- Extractable props: `connected` (boolean), `pendingCount` (number|null)
- Hardcoded: "AgentDesk" text, ⚙ 設定 label, all CSS

## TriageCard
- Source: `web/app.js` renderCard + style.css (.card*)
- Category: basic
- Description: main triage card — countdown strip, header (avatar/agent/time/severity), impact row, confidence bar, summary, A2UI components, actions row
- Extractable props: `agentName`, `severity` (info|warning|critical), `summary`, `confidence` (0-1), `expiresAt`, `onExpire`, `impactSummary`, `reversible`
- Hardcoded: card CSS, button labels ✕/Inspect/Snooze, badge styles

## MiniRow
- Source: `web/app.js` render() queue loop
- Category: basic
- Description: compact queued-task row (severity badge + agent + summary, 72% opacity)
- Extractable props: `severity`, `agentName`, `summary`, `snoozed`
- Hardcoded: all CSS

## InspectSheet
- Source: `web/app.js` renderInspect + style.css (.sheet*)
- Category: layout
- Description: bottom sheet with dynamic A2UI form (time/date/slider/segmented/text) and 修正して承認
- Extractable props: `title`
- Hardcoded: form field styles, button labels

## Toast
- Source: `web/app.js` toast()
- Category: basic
- Description: bottom-center pill toast with optional 元に戻す action
- Extractable props: `message`, `showUndo`
- Hardcoded: all CSS
