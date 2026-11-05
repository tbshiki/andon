# andon のアイコン

工場のアンドン（赤・黄・緑の三段の積層灯）をモチーフにした、背景が透明なアイコンです。画像生成には組み込みの `image_gen` ツールを使用しました。

各色のレンズに猫のシルエットを入れています。赤は毛を逆立てて警戒する猫、黄は軽快に跳ねる猫、緑は丸くなって眠る猫です。

シルエットはレンズの曲面に沿わせ、光沢と各色の透過光を重ねて、レンズに印刷された質感にしています。

- `source/andon.png`: 生成された原画像（1254 × 1254、RGBA）。下の 2 つの元。表示には使わない。
- `andon-192.png`: README の表示用（192 × 192）。README では幅 96 px で表示し、高 DPI の画面のために 2 倍の大きさにしている。
- `../andon.ico`: Windows 用。16・20・24・32・40・48・64・96・128・256 px を収録。ウィンドウとショートカットで使用。配るファイルで、`andon.ps1` が同じフォルダから読むので、ルートに置く。

ICO と `andon-192.png` は、原画像を Pillow で縮小して作成しました。通知領域の状態表示には、赤・黄・緑・灰の丸を使います。

`andon-192.png` は、透明な縁に色がにじまないよう、アルファを掛けた状態で縮小しています。作り直すときは、リポジトリのルートで次を実行します。

```powershell
python -c "from PIL import Image; Image.open('assets/source/andon.png').convert('RGBa').resize((192, 192), Image.Resampling.LANCZOS).convert('RGBA').save('assets/andon-192.png', optimize=True)"
```

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

## 猫のシルエットを追加した編集プロンプト

組み込みの `image_gen` ツールで、上記の原画像を編集しました。

```text
Use case: precise-object-edit
Asset type: transparent Windows application icon.
Input image: Image 1 is the exact edit target, the existing factory andon stack light icon.
Primary request: Add exactly one bold dark cat silhouette centered on each of the three colored lenses. Communicate three distinct moods through posture alone: TOP RED lens = danger / alarm, a tense defensive cat in side profile with strongly arched back, bristling fur, puffed upright curved tail, ears pinned back; MIDDLE AMBER-YELLOW lens = lighthearted and lively, a playful cat joyfully bounding or prancing sideways with a buoyant curved tail; BOTTOM GREEN lens = relaxation, a sleeping cat curled into a soft low oval, head resting on its paws and tail wrapped around its body.
Style: Flat solid almost-black graphite silhouettes printed onto the lens faces, with crisp simple contours, no face lines, no internal fur details. All three must clearly read as cats from ears, bodies and tails; each pose must be clearly different. Large, bold and legible, about 60 percent of each lens width and 65 percent of its height, with comfortable clear margin inside that lens. Preserve bright colored lens area around each silhouette. The cats are 2D markings on the light, not physical 3D cats sitting in front of it.
Invariants: Preserve the existing housing, pedestal, base, exact three-tier red/amber/green order, proportions, near-front perspective, lens colors, subtle 3D lighting and material treatment, outer silhouette and centered square framing. Preserve genuinely transparent background and clean alpha edges. Do not redesign the signal light.
Avoid: Text, letters, numbers, extra symbols, exclamation marks, extra animals, cats outside the colored lenses, background scenery, opaque background, badge, grid, watermark.
```

## 曲面と質感になじませた編集プロンプト

組み込みの `image_gen` ツールで、猫を追加した画像をさらに編集しました。

```text
Use case: precise-object-edit
Asset type: transparent Windows application icon, material integration refinement.
Input image: Image 1 is the exact edit target: a rounded cylindrical factory andon stack light, with a warning cat on the red lens, a playful bounding cat on the amber lens, and a curled sleeping cat on the green lens.
Primary request: Make the three existing dark cat markings convincingly conform to and belong to the rounded cylindrical lens surfaces. They currently look like flat graphics floating over the image. Treat each silhouette as dark translucent ink screen-printed underneath the glossy curved outer lens, rather than a graphic pasted on a flat image plane. Wrap and gently warp each cat around the cylinder, following the same bowed horizontal surface curvature as the lens and black separator rims. Show subtly greater foreshortening at left and right and smooth curved baselines. Preserve all three original cat poses and recognizable outlines.
Material integration: The same broad soft lens reflections and highlights must flow continuously OVER the cat ink, unifying the marking with its lens. Introduce subtle shading and specular variation across the cat ink, consistent with the lens curvature, and very subdued red/amber/green internal light transmission tint respectively. Keep silhouettes dark charcoal and highly readable, but eliminate their unnaturally uniform flat black fill. The result should look like markings manufactured into the curved glowing plastic. Keep contours clean, not blurred. No bevel, extruded edge, embossing, cast shadow, floating decal, outline border, or added details on the cats. Understated physically plausible material integration.
Invariants: Keep the exact three cats, their mood and placement: red tense arched bristling cat; amber lively prancing cat; green relaxed sleeping curled cat. Preserve the existing lamp's exact overall geometry, size, framing, near-front view, dark graphite housing, short pedestal, base, three-tier red/amber/green order, lens colors and positions. Keep square canvas and genuinely transparent background with clean alpha edges. Change only the cats' surface projection and their integration with the lens light and finish.
Avoid: Redesigning cats, replacing silhouettes with 3D animals, new symbols, text, opaque background, grid, watermark, extra objects.
```
