import Foundation

public enum ZeddyLogo {
    public static let svgContent = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 800" width="100%" height="100%">
  <defs>
    <radialGradient id="bgGlow" cx="50%" cy="45%" r="65%">
      <stop offset="0%" stop-color="#180b2a"/>
      <stop offset="55%" stop-color="#090514"/>
      <stop offset="100%" stop-color="#020106"/>
    </radialGradient>
    <linearGradient id="neonCyan" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#00f3ff"/>
      <stop offset="100%" stop-color="#0066ff"/>
    </linearGradient>
    <linearGradient id="neonMagenta" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#ff007f"/>
      <stop offset="50%" stop-color="#ff003c"/>
      <stop offset="100%" stop-color="#7a00ff"/>
    </linearGradient>
    <linearGradient id="metalDark" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#2a2438"/>
      <stop offset="50%" stop-color="#171322"/>
      <stop offset="100%" stop-color="#0c0915"/>
    </linearGradient>
    <linearGradient id="chromeZ" x1="20%" y1="0%" x2="80%" y2="100%">
      <stop offset="0%" stop-color="#ffffff"/>
      <stop offset="25%" stop-color="#d4f7ff"/>
      <stop offset="50%" stop-color="#00f3ff"/>
      <stop offset="75%" stop-color="#7a00ff"/>
      <stop offset="100%" stop-color="#ff007f"/>
    </linearGradient>
    <pattern id="mangaDots" x="0" y="0" width="16" height="16" patternUnits="userSpaceOnUse">
      <circle cx="4" cy="4" r="1.5" fill="#ff007f" opacity="0.18"/>
      <circle cx="12" cy="12" r="1.5" fill="#00f3ff" opacity="0.15"/>
    </pattern>
    <filter id="hyperGlow" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="8" result="blur"/>
      <feMerge>
        <feMergeNode in="blur"/>
        <feMergeNode in="blur"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>
    <filter id="mangaImpact">
      <feDropShadow dx="6" dy="8" stdDeviation="0" flood-color="#ff0055"/>
      <feDropShadow dx="-4" dy="-4" stdDeviation="0" flood-color="#00f3ff"/>
    </filter>
  </defs>

  <rect width="800" height="800" rx="140" fill="url(#bgGlow)"/>
  <rect width="800" height="800" rx="140" fill="url(#mangaDots)"/>

  <g opacity="0.22" stroke="#00f3ff" stroke-width="1.5">
    <line x1="400" y1="400" x2="40" y2="40" stroke-width="3"/>
    <line x1="400" y1="400" x2="160" y2="20"/>
    <line x1="400" y1="400" x2="280" y2="10"/>
    <line x1="400" y1="400" x2="400" y2="5"/>
    <line x1="400" y1="400" x2="520" y2="10"/>
    <line x1="400" y1="400" x2="640" y2="20"/>
    <line x1="400" y1="400" x2="760" y2="40" stroke-width="3"/>
    <line x1="400" y1="400" x2="780" y2="160"/>
    <line x1="400" y1="400" x2="795" y2="280"/>
    <line x1="400" y1="400" x2="800" y2="400"/>
    <line x1="400" y1="400" x2="795" y2="520"/>
    <line x1="400" y1="400" x2="780" y2="640"/>
    <line x1="400" y1="400" x2="760" y2="760" stroke-width="3"/>
    <line x1="400" y1="400" x2="640" y2="780"/>
    <line x1="400" y1="400" x2="520" y2="790"/>
    <line x1="400" y1="400" x2="400" y2="795"/>
    <line x1="400" y1="400" x2="280" y2="790"/>
    <line x1="400" y1="400" x2="160" y2="780"/>
    <line x1="400" y1="400" x2="40" y2="760" stroke-width="3"/>
    <line x1="400" y1="400" x2="20" y2="640"/>
    <line x1="400" y1="400" x2="5" y2="520"/>
    <line x1="400" y1="400" x2="0" y2="400"/>
    <line x1="400" y1="400" x2="5" y2="280"/>
    <line x1="400" y1="400" x2="20" y2="160"/>
  </g>

  <g filter="url(#hyperGlow)">
    <polygon points="400,90 690,400 400,710 110,400" fill="none" stroke="url(#neonCyan)" stroke-width="5" stroke-dasharray="14 8"/>
    <polygon points="400,108 672,400 400,692 128,400" fill="none" stroke="url(#neonMagenta)" stroke-width="2.5" opacity="0.7"/>
  </g>

  <g transform="translate(0, -10)">
    <path d="M 270 290 L 190 140 L 290 220 Z" fill="url(#neonMagenta)" stroke="#ffffff" stroke-width="2"/>
    <path d="M 530 290 L 610 140 L 510 220 Z" fill="url(#neonCyan)" stroke="#ffffff" stroke-width="2"/>
    <line x1="190" y1="140" x2="260" y2="230" stroke="#00f3ff" stroke-width="4" stroke-linecap="round"/>
    <line x1="610" y1="140" x2="540" y2="230" stroke="#ff007f" stroke-width="4" stroke-linecap="round"/>

    <polygon points="260,250 540,250 600,430 400,560 200,430" fill="url(#metalDark)" stroke="#00f3ff" stroke-width="6"/>
    <polygon points="280,270 520,270 560,410 400,520 240,410" fill="#080511" stroke="#251a3d" stroke-width="3"/>

    <path d="M 270 290 L 510 290 L 530 330 L 380 430 L 520 430 L 490 490 L 250 490 L 230 450 L 390 350 L 250 350 Z"
          fill="url(#chromeZ)"
          stroke="#ffffff"
          stroke-width="5"
          stroke-linejoin="miter"
          filter="url(#mangaImpact)"/>

    <polygon points="270,395 360,405 345,420 280,415" fill="#00f3ff" filter="url(#hyperGlow)"/>
    <polygon points="285,402 335,408 330,414 290,411" fill="#ffffff"/>

    <polygon points="530,395 440,405 455,420 520,415" fill="#ff007f" filter="url(#hyperGlow)"/>
    <polygon points="515,402 465,408 470,414 510,411" fill="#ffffff"/>

    <rect x="340" y="275" width="120" height="14" rx="4" fill="#000000" stroke="#00f3ff" stroke-width="2"/>
    <circle cx="360" cy="282" r="3.5" fill="#00f3ff"/>
    <circle cx="380" cy="282" r="3.5" fill="#00f3ff"/>
    <circle cx="400" cy="282" r="3.5" fill="#ffffff" filter="url(#hyperGlow)"/>
    <circle cx="420" cy="282" r="3.5" fill="#ff007f"/>
    <circle cx="440" cy="282" r="3.5" fill="#ff007f"/>

    <line x1="200" y1="430" x2="160" y2="460" stroke="#00f3ff" stroke-width="4" stroke-linecap="round"/>
    <line x1="600" y1="430" x2="640" y2="460" stroke="#ff007f" stroke-width="4" stroke-linecap="round"/>
    <circle cx="160" cy="460" r="5" fill="#00f3ff"/>
    <circle cx="640" cy="460" r="5" fill="#ff007f"/>
  </g>

  <g font-family="'Impact', 'Hiragino Kaku Gothic Pro', 'Noto Sans JP', sans-serif" font-weight="900" font-size="46" fill="#ff0055" stroke="#ffffff" stroke-width="2" opacity="0.85">
    <text x="70" y="240" transform="rotate(-15, 70, 240)">ズ</text>
    <text x="95" y="190" transform="rotate(-10, 95, 190)" font-size="56" fill="#00f3ff">ッ</text>
    <text x="140" y="145" transform="rotate(-5, 140, 145)" font-size="64">デ</text>
    <text x="630" y="200" transform="rotate(12, 630, 200)" font-size="58" fill="#00f3ff">ィ</text>
    <text x="680" y="260" transform="rotate(18, 680, 260)" font-size="50">!</text>
  </g>

  <g transform="translate(400, 640)">
    <text x="0" y="0" font-family="'Arial Black', 'Impact', sans-serif" font-weight="900" font-style="italic" font-size="92" letter-spacing="6" text-anchor="middle" fill="#000000" stroke="#ff007f" stroke-width="14" stroke-linejoin="round">ZEDDY</text>
    <text x="0" y="0" font-family="'Arial Black', 'Impact', sans-serif" font-weight="900" font-style="italic" font-size="92" letter-spacing="6" text-anchor="middle" fill="#ffffff" stroke="#00f3ff" stroke-width="5" stroke-linejoin="round">ZEDDY</text>
    <rect x="-180" y="24" width="360" height="28" rx="7" fill="#0c071a" stroke="#00f3ff" stroke-width="2"/>
    <text x="0" y="43" font-family="'SF Pro Display', 'Menlo', 'Arial Black', sans-serif" font-weight="900" font-size="14" letter-spacing="5" text-anchor="middle" fill="#00f3ff">FTS5 • BM25 • LOCAL ENGINE</text>
  </g>

  <polygon points="120,320 150,335 130,345" fill="#ffffff" opacity="0.8"/>
  <polygon points="680,310 650,325 670,340" fill="#ffffff" opacity="0.8"/>
  <polygon points="380,180 400,165 420,180 400,195" fill="#00f3ff" filter="url(#hyperGlow)"/>
  <circle cx="210" cy="530" r="4" fill="#ff007f"/>
  <circle cx="590" cy="530" r="4" fill="#00f3ff"/>
</svg>
"""

    public static func ensureFileExists() {
        let path = Paths.logoSvgFile
        if !FileManager.default.fileExists(atPath: path) {
            try? Paths.ensureLayout()
            try? svgContent.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
