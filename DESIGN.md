# 0.8.4 interface specification

Purpose: operate a private local photo library with quick review, reversible staging, search and trips.
Direction: refined native Apple interface. SF Pro / PingFang, Dynamic Type, SF Symbols; content takes priority over ornament.
Four tabs: organize, trips, pending, AI. Existing person associations remain in storage, without a separate people tab.
Canvas: system #F7F8FA / #101214; white #FFFFFF, black #000000, sage #EDF3EE, cream #F5F1E8, rose #F8EEF1, custom RGB.
System semantic text colors; custom background luminance determines light or dark text. Accent #286D88 / #9ED7EB; destructive system red.
Spacing: 4/8/12/16/20/28 points. Search radius 14; content card radius 18; photo radius 10; all actions at least 44 points high.
Glass: system tab/navigation chrome and glass action buttons on iOS 26+, material fallback on iOS 17+. No duplicate blur overlays on native glass.
Pending grid: reusable native cells, bounded 320 px thumbnails, long-press range selection with baseline/reversal and edge auto-scroll. No full collection reload when only selection changes.
Keep the existing three-image review cache and card spring gestures unchanged.
Search: metadata results immediately, explicit language selection internally, simplified/traditional variants, distinct judge/baguette aliases; visual results arrive as the persistent index builds. Never silently use a paid API.
Validation: pure range/search/color tests; UI tests for drag, native review routes, metadata search without an index, saved custom background, and real PhotoKit deletion cancellation.
