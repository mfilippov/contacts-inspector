# Button inside ScrollView in `.inspector` does not receive clicks (macOS 27)

**Environment:** macOS 27.0 (26A428), Xcode SDK macOS 27.0, Swift 6.4.

**Summary.** When a `ScrollView` is the root of `.inspector` content, SwiftUI buttons inside it
do not react to clicks. `hitTest` on the scroll view's `PlatformGroupContainer` returns the container itself
instead of the `SwiftUIAppKitButton` below the cursor. The same button works when the content is
`Form { }.formStyle(.grouped)` or `List`, when the `ScrollView` has a fixed height, or when there is any view
(for example, a `Divider`) above it. The following did not help: `.scrollEdgeEffectHidden(true, for: .top)`,
`.ignoresSafeArea(edges: .top)`, `.contentMargins(.top, 0)`, a zero-height view above the ScrollView.

**Steps.**
```sh
swift build -c release
mkdir -p Repro.app/Contents/MacOS && cp .build/release/InspectorScrollButton Repro.app/Contents/MacOS/
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string InspectorScrollButton" \
  -c "Add :CFBundleIdentifier string repro.InspectorScrollButton" -c "Add :CFBundlePackageType string APPL" \
  Repro.app/Contents/Info.plist
codesign --force --sign - Repro.app
open -n Repro.app --args $PWD/scroll.log scroll && sleep 5 && cat scroll.log
open -n Repro.app --args $PWD/form.log form && sleep 5 && cat form.log
```

**Expected:** `ACTION inspector` in both logs. **Actual:** in `scroll` mode only `ACTION detail`,
`hitTest=PlatformGroupContainer`.

Workaround in Contacts Inspector: the inspector cards use `Form(.grouped)`.
