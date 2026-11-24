//
//  TerminalSurface+ScreenText.swift
//  AIBCC patch (see PATCHES.md, patch 3)
//

import Foundation
import GhosttyKit

extension TerminalSurface {
    /// The whole screen — scrollback and viewport — as text, from the first
    /// cell to the last. Ghostty joins soft-wrapped rows.
    func readScreenText() -> String? {
        guard let surface = rawValue else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false,
        )
        var result = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &result) else { return nil }
        defer { ghostty_surface_free_text(surface, &result) }
        return result.text.map {
            String(decoding: UnsafeRawBufferPointer(start: $0, count: Int(result.text_len)), as: UTF8.self)
        } ?? ""
    }
}

#if !canImport(UIKit) && canImport(AppKit)
    extension AppTerminalView {
        /// AIBCC patch: the terminal's full text for "export output".
        public func readScreenText() -> String? {
            surface?.readScreenText()
        }
    }
#endif
