# Settings design

Mode: Operate. A calm, native macOS workspace for adjusting a local writing assistant.

Use a single system accent, monochrome SF Symbols, semantic system surfaces, and native controls. Group navigation by task, provide pane search, and give every pane a concise purpose. Keep keyboard navigation, pane restoration, Command-comma access, and all existing settings. Avoid rainbow icon tiles and decorative gradients. Privacy descriptions must distinguish local inference, retained writing, optional encrypted sync, Accessibility conversation reads, and screenshot opt-ins.

Keep the outer navigation column at 224 points and let the detail column resize with the window. Native split-view hosting shifted its header outside the content area on the tested macOS build; the ordinary stack keeps the headers inside AppKit's content layout guide without a fixed title-bar spacer. The Apps pane retains its inner resizable list.

Verify the built native window in light and dark appearances, at its minimum and normal sizes, with long panes scrolled and search/keyboard navigation exercised. Screenshots are evidence of the tested build only; they do not certify accessibility or prediction quality.
