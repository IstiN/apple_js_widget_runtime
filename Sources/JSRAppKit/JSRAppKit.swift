// macOS mapping: jsr nodes -> AppKit. Thin layer; all logic lives in JSRCore.
// column -> vertical NSStackView, row -> horizontal NSStackView,
// text -> NSTextField (label), textButton -> NSButton, scroll -> NSScrollView.
// Every root gets accessibilityIdentifier = nodeId (AUI dump anchor).
