// iOS mapping: jsr nodes -> UIKit. Thin layer; all logic lives in JSRCore.
// column -> vertical UIStackView, row -> horizontal UIStackView,
// text -> UILabel, textButton -> UIButton, container/card -> UIView+layer,
// scroll -> UIScrollView, center -> centered NSLayoutConstraint pair.
// Every root gets accessibilityIdentifier = nodeId (AUI dump anchor).
