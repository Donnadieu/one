# Design

- **Visual language:** the "world": a dark stage (`WorldLook.bg` #141416, cream #F4EFE8), the assistant as
  seven soft wobbling rings (`Presence`, gold inside to teal outside), things it can reach as upright
  tiles drifting around it. Connected = glowing thread with a travelling dot; not built = faint.
- **No stock patterns** for new screens (settings lists, toggles, chat sidebars). Start from the world.
- **Pop-ups:** one glass for all (Claude Design "Popup Glass", A · Smoked glass, Oct 28): the window's own smoked
  glass, corner 20, 30% dim behind, X top right with "Esc to close", and they close with the X, a click outside
  or Esc. Build them with `PopupStage` / `.onePopup` (Sources/PopupGlass.swift), never a Mac sheet, popover or alert
  (one-lint `popup-glass`). Inner cards: `.popupCard()` (cream 4%).
- **Selected** = outline + check. The filled cream pill is only for the main action.
- **Words:** short, plain, numbered steps. Name things people understand ("Ready for you", "rooms", "helpers")
  and explain them in the app.
- **Voice first:** speech starts before or with the text.
- **Process:** render with `One --render-world <prefix>`, show it, wait for a yes, then install.
