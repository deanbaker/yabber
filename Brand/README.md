# Yabber brand assets

A first-pass asset pack for the Yabber iOS app and website.

## Included

- iOS app icon (1024×1024, universal): lives in the app at `App/Yabber/Assets.xcassets/AppIcon.appiconset/`.
- `source/yabber-app-icon.svg` — editable full-square app icon artwork.
- `source/yabber-mark.svg` — transparent scalable symbol artwork.
- `source/yabber-wordmark.svg` — scalable symbol + wordmark lockup.
- `web/favicon.svg` and `web/favicon.ico` — browser favicons.
- `web/apple-touch-icon.png` — 180×180 touch icon.
- `web/pwa-icon-192.png` and `web/pwa-icon-512.png` — PWA icons.
- `web/yabber-mark-512.png` and `web/yabber-wordmark.png` — general-use PNGs.
- `social/og-image.png` — 1200×630 social sharing preview.

## iOS

The app icon is already wired in at `App/Yabber/Assets.xcassets/AppIcon.appiconset/`. The 1024px icon is full-bleed square; iOS applies the rounded mask.

## Web

Example HTML:
```html
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
```

Example PWA manifest icons:
```json
{
  "icons": [
    { "src": "/pwa-icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/pwa-icon-512.png", "sizes": "512x512", "type": "image/png" }
  ]
}
```

## Palette

- Near-black: `#0B0B0D`
- Warm orange: `#FF790D`
- Amber highlight: `#FFB21A`
- Deep orange: `#F04412`

The SVG files are editable vector artwork. This is a first-pass visual identity; review the mark at small sizes before shipping.
