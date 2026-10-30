/**
 * Visual inset around every xterm view. It must sit on a wrapper OUTSIDE xterm's
 * parent element: FitAddon sizes the terminal from the parent's computed
 * (border-box) width/height, so padding on the parent itself over-estimates
 * cols/rows and the last row/column ends up clipped or under the scrollbar.
 */
export const TERMINAL_INSET = "4px 8px";
