# andon のアイコン

工場のアンドン（赤・黄・緑の三段の積層灯）をモチーフにした、背景が透明なアイコンです。画像生成には組み込みの `image_gen` ツールを使用しました。

- `andon.png`: 生成された原画像（1254 × 1254、RGBA）。README などの表示用。
- `../andon.ico`: Windows 用。16・20・24・32・40・48・64・96・128・256 px を収録。ウィンドウとショートカットで使用。

ICO は原画像を Pillow で各サイズへ縮小して作成しました。通知領域の状態表示には、従来の赤・黄・灰の丸を使います。

## 生成プロンプト

```text
Use case: logo-brand
Asset type: Windows desktop application icon for a small factory-andon-inspired session monitor named andon.
Primary request: A single distinctive industrial andon stack signal light, three thick rounded illuminated tiers: red at top, amber-yellow in middle, green at bottom, in a compact charcoal graphite metal housing with a short sturdy pedestal and wide low base. This is the real factory stacked signal beacon motif, not a roadside traffic signal.
Style/medium: Beautifully polished, restrained 3D app icon, near-front view with very slight perspective, clean bold silhouette, subtle bevels, softly luminous colored lenses, dark crisp separators, minimal surface detail. Functional industrial character with a warm friendly presence.
Composition/framing: Square 1024x1024 canvas; a single centered standalone object, filling about 85 percent height and 65 percent width, balanced proportions and generous clear edge margin. The colored tiers should be broad and readily distinguishable at 16 to 32 pixels. Thick body, very short stem, no thin protrusions.
Scene/backdrop: Genuinely transparent background outside the object. No background tile or badge.
Constraints: Exactly three colored stacked tiers, red amber green in that vertical order. One final icon only. No words, no letters, no numbers, no logo overlays, no watermark, no grid, no presentation mockup, no factory scenery, no cables, no cast shadow outside the object. Preserve crisp alpha edges.
```
