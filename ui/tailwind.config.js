/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        mono: ['JetBrains Mono', 'Fira Code', 'monospace'],
      },
      colors: {
        bg: '#0d1117',
        surface: '#161b22',
        border: '#30363d',
        muted: '#7d8590',
      },
    },
  },
  plugins: [],
}
