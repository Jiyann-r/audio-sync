/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        canvas: '#040508',
        glass: {
          surface: 'rgba(23, 27, 43, 0.65)',
          border: 'rgba(255, 255, 255, 0.12)',
        },
        brand: {
          cyan: '#22d3ee',
          violet: '#a855f7',
          blurple: '#6366f1',
          emerald: '#10b981',
          rose: '#f43f5e',
          amber: '#f59e0b',
        }
      },
      borderRadius: {
        'card': '28px',
        'menu': '20px',
        'pill': '9999px',
      },
      transitionTimingFunction: {
        'spring': 'cubic-bezier(0.16, 1, 0.3, 1)',
      },
      boxShadow: {
        'glass-bevel': 'inset 0 1px 1px rgba(255, 255, 255, 0.18)',
        'glass-glow-cyan': '0 0 35px -8px rgba(34, 211, 238, 0.28)',
        'glass-glow-violet': '0 0 35px -8px rgba(168, 85, 247, 0.28)',
      }
    },
  },
  plugins: [],
}
